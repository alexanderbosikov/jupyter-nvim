"""Живое ядро: ZeroMQ-протокол Jupyter за фасадом. ARCHITECTURE.md §6.2, §4.2, §4.5.

Четыре свойства, определяющие устройство модуля:

1. Готовность определяется одним `kernel_info_request` со своим `msg_id` (§6.2). `wait_for_ready`
   не вызывается никогда: он сыплет запросами и дренирует iopub, унося вывод уже запущенных ячеек.
2. Регистрация в роутере происходит **до** отправки `execute_request`, поэтому сообщение не может
   приехать раньше своей записи. Для этого запрос собирается вручную — `msg_id` нужен заранее.
3. Прогон закрывается, когда пришли **и** `idle` с iopub, **и** `execute_reply` с shell: это разные
   каналы, порядок доставки не гарантирован, а статус ошибки живёт в реплае.
4. Готовность — это ответ на shell **и** живой iopub. iopub работает через PUB/SUB, подписка встаёт
   не мгновенно, и всё опубликованное до неё теряется безвозвратно. Проверено экспериментом: если
   объявить готовность по одному лишь `kernel_info_reply`, первая ячейка регулярно приезжает без
   вывода.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import threading
import time
from pathlib import Path
from queue import Empty
from typing import Any, Callable

from . import frames
from .mime import render as render_mime
from .outdir import RUNTIME_FILE
from .protocol import ErrCode, Ev, ExecStatus, KernelState
from .router import Exec, Router
from .rpc import Rpc, RpcError
from .stream import StreamBuffer, strip_ansi

RESULT_TYPES = {"execute_result", "display_data", "update_display_data"}

PROBE_CODE = "try:\n    input()\nexcept BaseException:\n    pass\n"
"""Скрытая ячейка для подтверждения маршрута stdin. См. `_settle_stdin`."""

GLOBAL_TYPES = {"status", "iopub_welcome"}
"""Сообщения без родителя по своей природе: не orphan, а служебный шум ядра."""

SILENT_TYPES = {"execute_input"}
"""Есть родитель, но показывать нечего: код ячейки Lua и так знает."""


class KernelSession:
    def __init__(
        self,
        rpc: Rpc,
        router: Router | None = None,
        *,
        outdir_for: Callable[[], Any] | None = None,
        poll: float = 0.1,
        history_limit: int = 5,
    ) -> None:
        self._rpc = rpc
        self._router = router or Router()
        self._outdir_for = outdir_for or (lambda: None)
        self._poll = poll
        self._history_limit = history_limit
        self._pending: dict[str, dict[str, Any]] = {}

        self._km: Any = None
        self._client: Any = None
        self._pump_stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._streams: dict[tuple[str, str], StreamBuffer] = {}
        self._lock = threading.Lock()

        self._state = KernelState.NONE
        self._state_t0 = time.monotonic()
        self._info_msg_ids: set[str] = set()
        self._shell_ready = False
        self._iopub_live = False
        self._stdin_live = False
        self._probe_msg_ids: set[str] = set()
        self._probe_seen = threading.Event()
        self._stdin_started = False
        self._ready_lock = threading.Lock()
        self._restarting = False
        self._banner: dict[str, Any] = {}
        self._kernel_log: Path | None = None
        self._kernel_log_fh: Any = None

    # ---------- состояние ----------

    @property
    def router(self) -> Router:
        return self._router

    def state(self) -> dict[str, Any]:
        return {
            "state": self._state,
            "since_ms": int((time.monotonic() - self._state_t0) * 1000),
            **self._banner,
        }

    def _set_state(self, state: str, **data: Any) -> None:
        if state == self._state:
            return
        self._state = state
        self._state_t0 = time.monotonic()
        self._rpc.event(Ev.KERNEL_STATE, state=state, **data)

    # ---------- жизненный цикл ----------

    def start(
        self,
        kernel_name: str = "python3",
        cwd: str | None = None,
        env: dict | None = None,
        log_file: str | None = None,
    ) -> dict[str, Any]:
        from jupyter_client.manager import KernelManager

        if self._km is not None:
            raise RpcError(ErrCode.BAD_REQUEST, "ядро уже запущено; нужен kernel.restart")

        self._set_state(KernelState.STARTING)
        self._km = KernelManager(kernel_name=kernel_name)
        launch = {"env": self._launch_env(env), "stderr": self._open_kernel_log(log_file)}
        if cwd:
            launch["cwd"] = cwd
        self._km.start_kernel(**launch)
        self._open_client()

        self._write_runtime(kernel_name)

        return {
            "kernel_id": os.path.basename(self._km.connection_file),
            "connection_file": self._km.connection_file,
            "kernel_name": kernel_name,
            "kernel_log": str(self._kernel_log),
        }

    def _launch_env(self, env: dict | None) -> dict[str, str]:
        """Окружение ядра: свой bin впереди PATH.

        kernelspec может задавать интерпретатор относительно — у venv'ного `python3` в argv
        стоит просто "python". Тогда ядро берётся из PATH, а он у nvim, запущенного из GUI,
        произвольный: в чистом PATH бинарника `python` может не быть вообще, и ячейка падает
        с ModuleNotFoundError на первом же импорте. Мы уже знаем нужный интерпретатор — тот,
        которым запущен сам сайдкар, — поэтому кладём его каталог первым. Абсолютные argv
        в kernelspec это никак не затрагивает.
        """
        merged = {**os.environ, **(env or {})}
        bin_dir = os.path.dirname(sys.executable)
        merged["PATH"] = os.pathsep.join([bin_dir, merged.get("PATH", "")]).rstrip(os.pathsep)
        return merged

    def _open_kernel_log(self, log_file: str | None) -> Any:
        """Свой файл для stderr ядра — не наследовать наш.

        ipykernel пишет туда собственные логи, включая безобидный баннер про TCP без
        шифрования на каждом старте. Унаследованный stderr означал бы, что этот баннер
        доезжает до пользователя как ошибка сайдкара, а настоящие падения тонут в шуме.
        Наш stderr остаётся только под наши трейсбеки.
        """
        self._kernel_log = Path(
            log_file or os.path.join(tempfile.gettempdir(), f"jupyter-nvim-kernel-{os.getpid()}.log")
        )
        self._kernel_log.parent.mkdir(parents=True, exist_ok=True)
        self._kernel_log_fh = self._kernel_log.open("ab")
        return self._kernel_log_fh

    def _open_client(self) -> None:
        self._client = self._km.client()
        self._client.start_channels()
        self._pump_stop = threading.Event()
        self._threads = []
        for name, getter in (
            ("iopub", self._client.get_iopub_msg),
            ("shell", self._client.get_shell_msg),
            ("stdin", self._client.get_stdin_msg),
        ):
            self._spawn(f"jn-{name}", self._pump, name, getter, self._pump_stop)
        self._spawn("jn-watchdog", self._watchdog, self._pump_stop)
        self._probe_ready()

    def _spawn(self, name: str, fn: Callable, *args: Any) -> None:
        t = threading.Thread(target=fn, args=args, daemon=True, name=name)
        t.start()
        self._threads.append(t)

    def _probe_ready(self) -> None:
        """§6.2: готовность = ответ на shell И живой iopub. `wait_for_ready` не вызывается никогда."""
        self._shell_ready = False
        self._iopub_live = False
        self._stdin_live = False
        self._info_msg_ids = set()
        self._probe_msg_ids = set()
        self._stdin_started = False
        self._set_state(KernelState.STARTING)
        self._send_kernel_info()
        self._spawn("jn-ready", self._ready_prober, self._pump_stop)

    def _send_hidden(self, code: str, allow_stdin: bool = False) -> str:
        """Скрытая ячейка: в историю не попадает, наверх её сообщения не уходят."""
        content = {
            "code": code,
            "silent": True,
            "store_history": False,
            "user_expressions": {},
            "allow_stdin": allow_stdin,
            "stop_on_error": False,
        }
        with self._lock:
            msg = self._client.session.msg("execute_request", content)
            self._probe_msg_ids.add(msg["header"]["msg_id"])
            self._client.shell_channel.send(msg)
        return msg["header"]["msg_id"]

    def _send_kernel_info(self) -> None:
        msg = self._client.session.msg("kernel_info_request", {})
        self._info_msg_ids.add(msg["header"]["msg_id"])
        self._client.shell_channel.send(msg)

    def _ready_prober(self, stop: threading.Event) -> None:
        """Пока iopub молчит, переспрашиваем kernel_info: его status-пара и докажет, что подписка жива.

        В отличие от `wait_for_ready`, здесь (а) iopub не дренируется, (б) цикл кончается на
        первом же полученном сообщении, (в) лишние status'ы отсекаются роутером по чужому родителю.
        """
        for _ in range(60):
            if stop.wait(0.15) or self._iopub_live or self._km is None:
                return
            try:
                self._send_kernel_info()
            except Exception:
                return

    def _settle_stdin(self, stop: threading.Event) -> None:
        """Подтвердить маршрут stdin настоящим `input()`, а не сном.

        ROUTER ядра узнаёт нашу identity только после того, как DEALER подключился, а посланный до
        этого `input_request` теряется молча — измеренное окно 50–300 мс и зависит от нагрузки.
        Пустой `input_reply` заранее посылать нельзя: если он придёт в зазор между запросом и
        ожиданием ответа, ядро примет его за ответ пользователя и `input()` вернёт пустую строку.

        Поэтому — самопроверка: скрытая ячейка вызывает `input()`, мы отвечаем на её запрос.
        Пришёл запрос — маршрут есть. Не пришёл — ядро висит в ожидании, снимаем `interrupt`
        (его глотает `except BaseException`) и пробуем снова.
        """
        for _ in range(10):
            if stop.is_set() or self._km is None:
                return
            if self._probe_stdin(stop):
                self._stdin_live = True
                self._maybe_ready()
                return
            try:
                if not self._km.is_alive():
                    return
                self._km.interrupt_kernel()
            except Exception:
                return
        self._rpc.log("warn", "маршрут stdin не подтверждён: input() в ячейке может не сработать")
        self._stdin_live = True
        self._maybe_ready()

    def _probe_stdin(self, stop: threading.Event) -> bool:
        self._probe_seen.clear()
        self._send_hidden(PROBE_CODE, allow_stdin=True)
        return self._probe_seen.wait(0.4) and not stop.is_set()

    def _maybe_ready(self) -> None:
        """Этапы готовности строго последовательны, и порядок здесь не косметический.

        Проба stdin умеет снимать `interrupt`, а SIGINT, прилетевший в ядро, которое ещё импортирует
        модули, обрывает его собственный старт (наблюдалось под нагрузкой). Поэтому сначала ядро
        должно доказать, что его главный цикл жив — ответом на shell и живым iopub, — и только потом
        мы имеем право что-то ему прерывать. Внедрение помощника из §7.1 по той же причине едет здесь.
        """
        if not (self._shell_ready and self._iopub_live):
            return

        with self._ready_lock:
            begin_settle = not self._stdin_started
            self._stdin_started = True

        if begin_settle:
            self._send_hidden(frames.HELPER_SOURCE)
            self._spawn("jn-stdin-settle", self._settle_stdin, self._pump_stop)
            return

        if self._stdin_live and self._state == KernelState.STARTING:
            self._set_state(KernelState.READY, **self._banner)

    def restart(self) -> dict[str, Any]:
        self._require_km()
        self._restarting = True
        try:
            self._stop_pumps()
            aborted = self._router.abort_all()
            self._km.restart_kernel(now=False)
            self._streams.clear()
            # клиент пересоздаётся целиком: иначе очередь сокета переживает рестарт
            self._open_client()
        finally:
            self._restarting = False
        for ex in aborted:
            self._emit_done(ex)
        return {"kernel_id": os.path.basename(self._km.connection_file), "aborted": len(aborted)}

    def interrupt(self) -> dict[str, Any]:
        self._require_km()
        self._km.interrupt_kernel()
        return {"active": len(self._router)}

    def kernel_pid(self) -> int | None:
        """pid процесса ядра. Путь к нему зависит от версии jupyter_client — идём осторожно."""
        km = self._km
        if km is None:
            return None
        for owner in (getattr(km, "provisioner", None), km):
            proc = getattr(owner, "process", None) or getattr(owner, "kernel", None)
            pid = getattr(proc, "pid", None)
            if pid:
                return int(pid)
        return None

    def connection_file(self) -> str | None:
        return self._km.connection_file if self._km is not None else None

    def _write_runtime(self, kernel_name: str) -> None:
        """Оставить след: кто держит ядро и какой у него pid.

        Нужно, чтобы осиротевшее ядро можно было опознать. nvim не ждёт нашего
        завершения — иначе выход из редактора стоил бы полторы секунды, — а мы можем
        не дожить до гашения: SIGKILL, падение интерпретатора, что угодно. Тогда ядро
        останется жить, и заметить это можно только по записи: сайдкара нет, а pid
        ядра ещё отвечает.
        """
        outdir = self._outdir_for()
        if outdir is None:
            return
        record = {
            "sidecar_pid": os.getpid(),
            "owner_pid": os.getppid(),  # nvim
            "kernel_pid": self.kernel_pid(),
            "kernel_name": kernel_name,
            # по нему ядро опознаётся в списке процессов: путь уникален и стоит в его argv
            "connection_file": self._km.connection_file,
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        }
        try:
            path = outdir.base / RUNTIME_FILE
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
        except OSError as e:
            self._rpc.log("warn", f"не удалось записать {RUNTIME_FILE}: {e}")

    def _clear_runtime(self) -> None:
        outdir = self._outdir_for()
        if outdir is None:
            return
        try:
            (outdir.base / RUNTIME_FILE).unlink(missing_ok=True)
        except OSError:
            pass

    def shutdown(self, deadline: float | None = None) -> dict[str, Any]:
        """Погасить ядро. `deadline` — сколько секунд ждать вежливого выхода.

        jupyter_client шлёт SIGTERM на половине этого срока и SIGKILL в конце, так что
        малый deadline — это гарантия, что ядро умрёт быстро. Дефолт (5 с) оставлен для
        явного `kernel.shutdown` от пользователя: там незачем торопиться.
        """
        if self._km is None:
            self._clear_runtime()
            return {}
        self._stop_pumps()
        for ex in self._router.abort_all():
            self._emit_done(ex)
        try:
            # мёртвое ядро гасить нечем: shutdown_request уйдёт в никуда, а jupyter_client
            # будет ждать его shutdown_wait_time (5 с) впустую
            if self._km.is_alive():
                if deadline is not None:
                    self._km.shutdown_wait_time = deadline
                self._km.shutdown_kernel(now=False)
        except Exception as e:
            self._rpc.log("warn", f"гашение ядра: {type(e).__name__}: {e}")
        finally:
            self._clear_runtime()
            self._km.cleanup_resources()  # чтобы не оставлять kernel-*.json в runtime/
            if self._kernel_log_fh is not None:
                self._kernel_log_fh.close()
                self._kernel_log_fh = None
            self._km = None
            self._client = None
            self._set_state(KernelState.NONE)
        return {}

    def _stop_pumps(self) -> None:
        self._pump_stop.set()
        for t in self._threads:
            t.join(timeout=2.0)
        self._threads = []
        if self._client is not None:
            try:
                self._client.stop_channels()
            except Exception:
                pass

    def _require_km(self) -> None:
        if self._km is None:
            raise RpcError(ErrCode.KERNEL_DEAD, "ядро не запущено")

    # ---------- выполнение ----------

    def execute(
        self,
        cell_id: str,
        run_id: int,
        code: str,
        result_expr: str = "_",
        user_expressions: dict | None = None,
    ) -> dict[str, Any]:
        self._require_km()
        if self._state not in (KernelState.READY, KernelState.BUSY):
            raise RpcError(
                ErrCode.KERNEL_NOT_READY,
                f"ядро в состоянии {self._state}: запрос не отправлен",
                state=self._state,
            )

        exprs = dict(user_expressions or {})
        table_path = None
        outdir = self._outdir_for()
        if outdir is not None and result_expr:
            table_path = outdir.path_for(cell_id, run_id, "parquet")
            exprs["__jn"] = frames.dump_call(result_expr, table_path)

        content = {
            "code": code,
            "silent": False,
            "store_history": True,
            "user_expressions": exprs,
            "allow_stdin": True,
            "stop_on_error": True,
        }
        with self._lock:
            msg = self._client.session.msg("execute_request", content)
            msg_id = msg["header"]["msg_id"]
            ex = self._router.start(msg_id, cell_id, run_id)  # регистрация ДО отправки
            ex.code_sha = hashlib.sha256(code.encode()).hexdigest()[:8]
            self._pending[msg_id] = {"table_path": str(table_path) if table_path else None}
            self._client.shell_channel.send(msg)
        return {"msg_id": msg_id}

    def stdin_reply(self, value: str) -> dict[str, Any]:
        self._require_km()
        self._client.input(value)
        return {}

    # ---------- каналы ----------

    def _pump(self, name: str, getter: Callable, stop: threading.Event) -> None:
        handler = {"iopub": self._on_iopub, "shell": self._on_shell, "stdin": self._on_stdin}[name]
        while not stop.is_set():
            try:
                msg = getter(timeout=self._poll)
            except Empty:
                continue
            except Exception as e:
                if not stop.is_set():
                    self._rpc.log("error", f"канал {name} оборвался: {type(e).__name__}: {e}")
                return
            try:
                handler(msg)
            except Exception as e:  # один плохой месседж не должен убивать канал
                self._rpc.log("error", f"{name}: {type(e).__name__}: {e}", msg_type=msg.get("msg_type"))

    def _watchdog(self, stop: threading.Event) -> None:
        while not stop.wait(0.25):
            if self._restarting or self._km is None:
                continue
            try:
                alive = self._km.is_alive()
            except Exception:
                alive = False
            if not alive:
                self._on_death()
                return

    def _on_death(self) -> None:
        aborted = self._router.abort_all()
        self._set_state(KernelState.DEAD, reason="процесс ядра завершился")
        for ex in aborted:
            self._emit_done(ex)

    # ---------- обработка сообщений ----------

    def _on_iopub(self, msg: dict) -> None:
        if not self._iopub_live:
            self._iopub_live = True  # подписка жива: с этого момента вывод не теряется
            self._maybe_ready()

        mtype = msg["msg_type"]
        parent = (msg.get("parent_header") or {}).get("msg_id")
        content = msg.get("content") or {}
        res = self._router.resolve(parent)

        if res.exec is None:
            self._on_unowned(mtype, parent, content)
            return

        ex, late = res.exec, res.origin == "finished"

        if mtype == "status":
            phase = content.get("execution_state")
            if late:
                return
            if phase == "busy":
                self._set_state(KernelState.BUSY)
                self._emit(Ev.EXEC_STARTED, ex, False, msg_id=ex.msg_id, started_at=ex.started_at)
            elif phase == "idle":
                ex.saw_idle = True
                self._maybe_close(ex)
            return

        if mtype == "stream":
            name = content.get("name", "stdout")
            buf = self._streams.setdefault((ex.msg_id, name), StreamBuffer())
            ops = buf.feed(content.get("text", ""))
            if ops:
                self._emit(Ev.STREAM, ex, late, name=name, ops=[o.as_dict() for o in ops])
            return

        if mtype == "error":
            traceback = [strip_ansi(line) for line in content.get("traceback") or []]
            if not late:
                pending = self._pending.setdefault(ex.msg_id, {})
                pending["ename"] = content.get("ename")
                pending["traceback"] = traceback
            self._emit(
                Ev.EXEC_ERROR,
                ex,
                late,
                ename=content.get("ename"),
                evalue=content.get("evalue"),
                traceback=traceback,
            )
            return

        if mtype in RESULT_TYPES:
            payload = render_mime(
                content.get("data") or {},
                outdir=self._outdir_for(),
                cell_id=ex.cell_id,
                run_id=ex.run_id,
            )
            if not late:
                pending = self._pending.setdefault(ex.msg_id, {})
                if payload.get("kind") == "image":
                    pending["kind"], pending["path"] = "image", payload.get("path")
                elif payload.get("kind") in ("text", "html") and payload.get("text"):
                    pending["result_text"] = payload["text"]
            ev = Ev.RESULT if mtype == "execute_result" else Ev.DISPLAY
            self._emit(ev, ex, late, **payload)
            return

        if mtype == "clear_output":
            self._streams.pop((ex.msg_id, "stdout"), None)
            self._streams.pop((ex.msg_id, "stderr"), None)
            self._emit(Ev.CLEAR_OUTPUT, ex, late, wait=content.get("wait", False))
            return

        if mtype in SILENT_TYPES:
            return

        self._rpc.log("debug", f"iopub без обработчика: {mtype}", cell_id=ex.cell_id)

    def _on_unowned(self, mtype: str, parent: str | None, content: dict) -> None:
        """Сообщение, не принадлежащее ни одному прогону.

        Разделение важное: `orphan` — это сообщение с *известным полем* parent, которого мы не знаем,
        то есть настоящая аномалия маршрутизации. А `parent_msg_id: null` — обычный вывод самого
        ядра (баннеры и предупреждения на старте), и его надо показать, а не считать сбоем.
        """
        if mtype in GLOBAL_TYPES or parent in self._probe_msg_ids:
            return

        if parent is None:
            if mtype == "stream":
                text = (content.get("text") or "").rstrip("\n")
                if text:
                    self._rpc.log("kernel", text, name=content.get("name", "stdout"))
            else:
                self._rpc.log("debug", f"iopub без родителя: {mtype}")
            return

        self._rpc.event(Ev.ORPHAN, parent_msg_id=parent, msg_type=mtype)

    def _on_shell(self, msg: dict) -> None:
        mtype = msg["msg_type"]
        parent = (msg.get("parent_header") or {}).get("msg_id")
        content = msg.get("content") or {}

        if mtype == "kernel_info_reply":
            if parent in self._info_msg_ids:
                impl = content.get("language_info") or {}
                self._banner = {
                    "implementation": content.get("implementation"),
                    "language": impl.get("name"),
                    "language_version": impl.get("version"),
                    "protocol_version": content.get("protocol_version"),
                }
                self._shell_ready = True
                self._maybe_ready()
            return

        if mtype == "execute_reply":
            res = self._router.resolve(parent)
            if res.exec is None:
                return
            ex = res.exec
            ex.reply_status = content.get("status")
            ex.execution_count = content.get("execution_count")
            ex.user_expressions = content.get("user_expressions") or {}
            ex.saw_reply = True
            if res.origin == "active":
                self._maybe_close(ex)
            return

    def _on_stdin(self, msg: dict) -> None:
        if msg["msg_type"] != "input_request":
            return
        content = msg.get("content") or {}
        parent = (msg.get("parent_header") or {}).get("msg_id")

        if parent in self._probe_msg_ids:  # это наша проба маршрута, наверх не показываем
            self._probe_seen.set()
            self._client.input("")
            return

        res = self._router.resolve(parent)
        ex = res.exec
        self._rpc.event(
            Ev.INPUT_REQUEST,
            cell_id=ex.cell_id if ex else None,
            run_id=ex.run_id if ex else None,
            prompt=content.get("prompt", ""),
            password=content.get("password", False),
        )

    # ---------- закрытие прогона ----------

    def _maybe_close(self, ex: Exec) -> None:
        """Закрываем, когда пришли оба конца. `aborted` закрывает сразу: своего idle он не получит."""
        aborted = ex.saw_reply and ex.reply_status == "aborted"
        if not aborted and not (ex.saw_idle and ex.saw_reply):
            return
        status = {
            "ok": ExecStatus.OK,
            "error": ExecStatus.ERROR,
            "aborted": ExecStatus.ABORTED,
        }.get(ex.reply_status or "ok", ExecStatus.OK)
        closed = self._router.finish(ex.msg_id, status)
        if closed is None:
            return

        stdout = self._streams.pop((ex.msg_id, "stdout"), None)
        stderr = self._streams.pop((ex.msg_id, "stderr"), None)
        pending = self._pending.pop(ex.msg_id, {})

        table = frames.parse_dump((closed.user_expressions or {}).get("__jn"))
        if table and pending.get("table_path"):
            self._emit(Ev.RESULT, closed, False, kind="table", path=pending["table_path"], **table)

        self._persist(closed, pending, table, stdout, stderr)
        self._emit_done(closed)
        if not len(self._router) and self._state == KernelState.BUSY:
            self._set_state(KernelState.READY)

    def _persist(
        self,
        ex: Exec,
        pending: dict[str, Any],
        table: dict[str, Any] | None,
        stdout: StreamBuffer | None,
        stderr: StreamBuffer | None,
    ) -> None:
        """Запись прогона в `.jupyter-out/`. Пути в индексе — относительные (§7), в событиях — полные."""
        outdir = self._outdir_for()
        if outdir is None:
            return

        record: dict[str, Any] = {
            "cell_id": ex.cell_id,
            "run_id": ex.run_id,
            "started_at": ex.started_at,
            "duration_ms": ex.duration_ms,
            "status": ex.status,
            "code_sha": ex.code_sha,
            "execution_count": ex.execution_count,
            "kind": "none",
            "path": None,
            "ename": pending.get("ename"),
        }

        if table and pending.get("table_path"):
            record.update(kind="table", path=self._rel(outdir, pending["table_path"]), **table)
        elif pending.get("kind") == "image" and pending.get("path"):
            record.update(kind="image", path=self._rel(outdir, pending["path"]))
        else:
            blob = "\n".join(
                part
                for part in (
                    stdout.text().rstrip("\n") if stdout else "",
                    stderr.text().rstrip("\n") if stderr else "",
                    pending.get("result_text", ""),
                    "\n".join(pending.get("traceback") or []),
                )
                if part
            )
            if blob:
                path = outdir.path_for(ex.cell_id, ex.run_id, "txt")
                path.write_text(blob + "\n", encoding="utf-8")
                record.update(kind="text", path=self._rel(outdir, path))

        try:
            outdir.append(record)
            outdir.prune(ex.cell_id, self._history_limit)
        except Exception as e:
            self._rpc.log("error", f"не удалось записать вывод: {type(e).__name__}: {e}")

    @staticmethod
    def _rel(outdir: Any, path: str | Any) -> str:
        from pathlib import Path

        try:
            return str(Path(str(path)).relative_to(outdir.base))
        except ValueError:
            return str(path)

    def table_page(
        self, path: str, offset: int = 0, limit: int = 100, cols=None, order_by=None
    ) -> dict[str, Any]:
        return frames.page(path, offset=offset, limit=limit, cols=cols, order_by=order_by)

    def _emit_done(self, ex: Exec) -> None:
        self._emit(
            Ev.EXEC_DONE,
            ex,
            False,
            status=ex.status,
            duration_ms=ex.duration_ms,
            execution_count=ex.execution_count,
            user_expressions=ex.user_expressions or None,
        )

    def _emit(self, ev: str, ex: Exec, late: bool, **data: Any) -> None:
        if late:
            data["late"] = True
        self._rpc.event(ev, cell_id=ex.cell_id, run_id=ex.run_id, **data)
