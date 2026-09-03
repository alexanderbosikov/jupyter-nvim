from jupyter_nvim.stream import StreamBuffer, strip_ansi


def ops(buf: StreamBuffer, text: str) -> list[tuple[str, str]]:
    return [(o.op, o.text) for o in buf.feed(text)]


def test_plain_lines_append():
    buf = StreamBuffer()

    assert ops(buf, "раз\nдва\n") == [("append", "раз"), ("append", "два")]


def test_partial_line_is_shown_then_completed():
    buf = StreamBuffer()

    assert ops(buf, "начало") == [("append", "начало")]
    assert ops(buf, " и конец\n") == [("replace_last", "начало и конец")]


def test_carriage_return_replaces_instead_of_appending():
    """Тест-лист §10: прогресс-бары и tqdm не должны сыпать сотнями строк."""
    buf = StreamBuffer()

    assert ops(buf, "50%\r") == [("append", "50%")]
    assert ops(buf, "75%") == [("replace_last", "75%")]
    assert ops(buf, "\r100%\n") == [("replace_last", "100%")]
    assert buf.text() == "100%\n"


def test_carriage_return_leaves_tail_of_longer_line():
    buf = StreamBuffer()
    buf.feed("аааааа\r")

    assert ops(buf, "бб") == [("replace_last", "ббаааа")]


def test_backspace_erases_previous_char():
    buf = StreamBuffer()

    assert ops(buf, "abc\b\bX") == [("append", "aXc")]


def test_backspace_does_not_run_past_line_start():
    buf = StreamBuffer()

    assert ops(buf, "a\b\b\bZ") == [("append", "Z")]


def test_ansi_is_stripped():
    buf = StreamBuffer()

    assert ops(buf, "\x1b[31mкрасный\x1b[0m\n") == [("append", "красный")]


def test_ansi_can_be_kept():
    buf = StreamBuffer(keep_ansi=True)

    assert ops(buf, "\x1b[31mx\x1b[0m\n")[0][1] == "\x1b[31mx\x1b[0m"


def test_strip_ansi_handles_cursor_and_erase_codes():
    assert strip_ansi("a\x1b[2K\x1b[1;32mb\x1b[0mc") == "abc"


def test_trailing_newline_does_not_emit_empty_line():
    buf = StreamBuffer()
    buf.feed("a\n")

    assert ops(buf, "b\n") == [("append", "b")]


def test_empty_feed_emits_nothing():
    buf = StreamBuffer()

    assert ops(buf, "") == []


def test_bare_newline_is_a_blank_output_line():
    """print() без аргументов — настоящая пустая строка, а не строка курсора."""
    buf = StreamBuffer()

    assert ops(buf, "\n") == [("append", "")]
    assert ops(buf, "a\n\n") == [("append", "a"), ("append", "")]


def test_progress_bar_across_many_feeds_emits_one_line():
    buf = StreamBuffer()
    all_ops = []
    for pct in range(0, 101, 10):
        all_ops += ops(buf, f"\r[{pct:3d}%]")

    assert [o[0] for o in all_ops] == ["append"] + ["replace_last"] * 10
    assert buf.text() == "[100%]"
