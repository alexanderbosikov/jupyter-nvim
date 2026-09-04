import pytest

from jupyter_nvim.protocol import ExecStatus
from jupyter_nvim.router import Router


@pytest.fixture
def router() -> Router:
    return Router()


def test_two_cells_in_flight_stay_separate(router):
    """Тест-лист §10: две ячейки в очереди — вывод не должен смешиваться."""
    router.start("m1", "a3f9", 1)
    router.start("m2", "b7e1", 2)

    assert (router.resolve("m1").exec.cell_id, router.resolve("m1").exec.run_id) == ("a3f9", 1)
    assert (router.resolve("m2").exec.cell_id, router.resolve("m2").exec.run_id) == ("b7e1", 2)
    assert len(router) == 2


def test_same_cell_rerun_keeps_runs_apart(router):
    router.start("m1", "a3f9", 1)
    router.finish("m1")
    router.start("m2", "a3f9", 2)

    assert router.resolve("m1").origin == "finished"
    assert router.resolve("m1").exec.run_id == 1
    assert router.resolve("m2").origin == "active"
    assert router.resolve("m2").exec.run_id == 2


def test_late_output_after_idle_is_late_not_orphan(router):
    """Вывод из фонового потока, напечатанный уже после `idle`."""
    router.start("m1", "a3f9", 1)
    router.finish("m1")

    res = router.resolve("m1")
    assert res.origin == "finished"
    assert res.exec.cell_id == "a3f9"


def test_unknown_parent_is_orphan(router):
    router.start("m1", "a3f9", 1)

    assert router.resolve("неизвестный").origin == "unknown"
    assert router.resolve(None).origin == "unknown"


def test_finish_closes_with_status_and_duration(router):
    router.start("m1", "a3f9", 1)
    ex = router.finish("m1", ExecStatus.ERROR)

    assert ex.status == ExecStatus.ERROR
    assert ex.duration_ms is not None and ex.duration_ms >= 0
    assert len(router) == 0
    assert router.finish("m1") is None


def test_abort_all_closes_every_active_run(router):
    """Рестарт или смерть ядра: своего `idle` не получит никто."""
    for i in range(3):
        router.start(f"m{i}", f"c{i}", i)

    aborted = router.abort_all()

    assert {ex.msg_id for ex in aborted} == {"m0", "m1", "m2"}
    assert all(ex.status == ExecStatus.ABORTED for ex in aborted)
    assert len(router) == 0
    assert router.resolve("m1").origin == "finished"


def test_active_for_cell(router):
    router.start("m1", "a3f9", 1)
    router.start("m2", "a3f9", 2)
    router.start("m3", "b7e1", 1)

    assert {ex.run_id for ex in router.active_for_cell("a3f9")} == {1, 2}
    assert len(router.active_for_cell("нет")) == 0


def test_finished_cap_evicts_oldest(router):
    small = Router(finished_cap=2)
    for i in range(3):
        small.start(f"m{i}", "a3f9", i)
        small.finish(f"m{i}")

    assert small.resolve("m0").origin == "unknown"
    assert small.resolve("m2").origin == "finished"


def test_started_at_is_utc_iso(router):
    ex = router.start("m1", "a3f9", 1)

    assert ex.started_at.endswith("+00:00")
