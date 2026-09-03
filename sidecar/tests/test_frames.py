"""Юниты на сериализацию датафрейма и постраничное чтение. ARCHITECTURE.md §7."""

import polars as pl
import pytest

from jupyter_nvim.frames import dump_call, page, parse_dump


def reply(text: str, status: str = "ok") -> dict:
    return {"status": status, "data": {"text/plain": text}}


def test_dump_call_quotes_the_path():
    call = dump_call("_", "/tmp/из отчёта/12.parquet")

    assert call.startswith("__jupyter_nvim_dump(_, ")
    assert "'/tmp/из отчёта/12.parquet'" in call


def test_parse_dump_reads_python_repr_not_json():
    """user_expressions отдаёт repr питоновского значения — одинарные кавычки, не JSON."""
    got = parse_dump(reply("{'rows': 3, 'cols': 2, 'schema': [['a', 'Int64'], ['b', 'String']]}"))

    assert got == {"rows": 3, "cols": 2, "schema": [["a", "Int64"], ["b", "String"]]}


@pytest.mark.parametrize(
    "entry",
    [
        None,
        {},
        reply("None"),
        reply(""),
        reply("{'rows': 1}", status="error"),
        reply("не питон"),
        reply("42"),
        reply("{'что-то': 'другое'}"),
    ],
)
def test_parse_dump_returns_none_for_everything_that_is_not_a_frame(entry):
    """Большинство ячеек таблицу не возвращает — это норма, а не ошибка."""
    assert parse_dump(entry) is None


@pytest.fixture
def parquet(tmp_path):
    path = tmp_path / "df.parquet"
    pl.DataFrame(
        {
            "id": range(250),
            "имя": [f"стр-{i}" for i in range(250)],
            "пусто": [None] * 250,
        }
    ).write_parquet(path)
    return path


def test_page_returns_header_and_strings(parquet):
    got = page(parquet, offset=0, limit=3)

    assert got["header"] == ["id", "имя", "пусто"]
    assert got["rows"] == [["0", "стр-0", ""], ["1", "стр-1", ""], ["2", "стр-2", ""]]
    assert got["total_rows"] == 250
    assert got["truncated"] is True


def test_page_slices_without_reading_everything(parquet):
    got = page(parquet, offset=248, limit=10)

    assert [row[0] for row in got["rows"]] == ["248", "249"]
    assert got["truncated"] is False


def test_page_clamps_offset_beyond_the_end(parquet):
    got = page(parquet, offset=10_000, limit=10)

    assert got["rows"] == []
    assert got["offset"] == 250
    assert got["truncated"] is False


def test_page_clamps_negative_offset(parquet):
    assert page(parquet, offset=-5, limit=1)["offset"] == 0


def test_page_selects_requested_columns_in_file_order(parquet):
    got = page(parquet, limit=1, cols=["имя", "id"])

    assert got["header"] == ["id", "имя"]
