"""Точка входа сайдкара: `python -m jupyter_nvim`. ARCHITECTURE.md §3, §4.2.

Здесь только проводка: op'ы протокола → методы `KernelSession`. Никакой логики, чтобы граница
из §3 оставалась проверяемой — сайдкар обязан работать из `echo '{...}' | python -m jupyter_nvim`.
"""

from __future__ import annotations

import atexit
import sys
from pathlib import Path

from . import __version__
from . import frames
from .kernel import KernelSession
from .outdir import DEFAULT_DIR, OutDir
from .protocol import ErrCode, Op, V
from .router import Router
from .rpc import Rpc, RpcError


class App:
    def __init__(self, rpc: Rpc | None = None) -> None:
        self.rpc = rpc or Rpc()
        self.outdir: OutDir | None = None
        self.session = KernelSession(self.rpc, Router(), outdir_for=lambda: self.outdir)
        self._register()

    def _register(self) -> None:
        rpc, session = self.rpc, self.session

        @rpc.op(Op.HELLO)
        def _hello(args: dict) -> dict:
            return {
                "v": V,
                "version": __version__,
                "python": sys.version.split()[0],
                "caps": ["execute", "interrupt", "stdin", "table.page"],
                "kernel": session.state(),
            }

        @rpc.op(Op.PING)
        def _ping(args: dict) -> dict:
            return {}

        @rpc.op(Op.KERNEL_START)
        def _start(args: dict) -> dict:
            notebook = args.get("notebook")
            if notebook:
                self.outdir = self._usable_outdir(
                    OutDir(Path(notebook), args.get("out_dir") or DEFAULT_DIR)
                )
            if args.get("history_limit"):
                session._history_limit = int(args["history_limit"])
            return session.start(
                kernel_name=args.get("kernel_name") or "python3",
                cwd=args.get("cwd"),
                env=args.get("env"),
                # лог ядра рядом с выводами, если ноутбук известен
                log_file=str(self.outdir.base / "kernel.log") if self.outdir else None,
            )

        @rpc.op(Op.KERNEL_STATE)
        def _state(args: dict) -> dict:
            return session.state()

        @rpc.op(Op.KERNEL_RESTART)
        def _restart(args: dict) -> dict:
            return session.restart()

        @rpc.op(Op.KERNEL_SHUTDOWN)
        def _shutdown(args: dict) -> dict:
            return session.shutdown()

        @rpc.op(Op.EXECUTE)
        def _execute(args: dict) -> dict:
            for key in ("cell_id", "run_id", "code"):
                if key not in args:
                    raise RpcError(ErrCode.BAD_ARGS, f"нет обязательного args.{key}")
            return session.execute(
                cell_id=args["cell_id"],
                run_id=args["run_id"],
                code=args["code"],
                result_expr=args.get("result_expr", "_"),
                user_expressions=args.get("user_expressions"),
            )

        @rpc.op(Op.TABLE_PAGE)
        def _page(args: dict) -> dict:
            if "path" not in args:
                raise RpcError(ErrCode.BAD_ARGS, "нет обязательного args.path")
            try:
                return session.table_page(
                    args["path"],
                    offset=args.get("offset", 0),
                    limit=args.get("limit", 100),
                    cols=args.get("cols"),
                    order_by=args.get("order_by"),
                )
            except FileNotFoundError:
                raise RpcError(ErrCode.NOT_FOUND, f"нет файла {args['path']}") from None
            except frames.UnknownColumn as e:
                raise RpcError(ErrCode.BAD_ARGS, str(e)) from None

        @rpc.op(Op.INTERRUPT)
        def _interrupt(args: dict) -> dict:
            return session.interrupt()

        @rpc.op(Op.STDIN_REPLY)
        def _stdin(args: dict) -> dict:
            if "value" not in args:
                raise RpcError(ErrCode.BAD_ARGS, "нет обязательного args.value")
            return session.stdin_reply(str(args["value"]))

    def _usable_outdir(self, outdir: OutDir) -> OutDir | None:
        """Каталог выводов — только если в него правда можно писать.

        Ноутбук может лежать там, где записи нет: примонтированная только для чтения
        шара, чужой каталог, ограниченные права. История в этом случае невозможна, но
        выполнение — вполне: это разные вещи, и вторая важнее. Раньше одна упавшая
        mkdir не давала стартовать ядру, то есть ноутбук в таком каталоге не работал
        вовсе, хотя ядру каталог не нужен.
        """
        try:
            outdir.base.mkdir(parents=True, exist_ok=True)
            probe = outdir.base / ".writable"
            probe.touch()
            probe.unlink()
        except OSError as e:
            self.rpc.log(
                "warn",
                f"история выключена: в {outdir.base} нельзя писать ({type(e).__name__}). "
                "Ячейки выполняются, но выводы не сохраняются",
            )
            return None
        return outdir

    def serve(self) -> None:
        # Короткий дедлайн: nvim закрыл stdin и не ждёт нас — он уже вышел или выходит.
        # Вежливого гашения хватает секунды, дальше jupyter_client сам добивает ядро
        # SIGTERM и SIGKILL. Дефолтные 5 с здесь означали бы только время, в течение
        # которого ядро живёт после закрытого редактора.
        atexit.register(lambda: self.session.shutdown(deadline=1.0))
        self.rpc.serve()
        self.session.shutdown(deadline=1.0)


def main() -> int:
    App().serve()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
