"""Прогресс-бар текстом, а не виджетом. ARCHITECTURE.md §6.6.

`tqdm.auto` в ядре с установленным `ipywidgets` выбирает `tqdm.notebook`, а тот рисует
бар не выводом, а виджетом: один `display_data` при создании и дальше `comm_msg` на
каждое обновление. Клиент без рантайма виджетов — а мы именно такой — видит только
первый кадр. Отсюда картина, ради которой всё это написано: ячейка, которая час гоняла
запросы по 73 окнам, всё это время показывала `Периоды: 0%| 0/73` и выглядела зависшей.

Держать своё состояние моделей ipywidgets ради одного прогресс-бара — это разбирать
чужой протокол и знать раскладку конкретной версии tqdm (HBox из FloatProgress и двух
HTML). Дешевле и честнее сказать ядру то, что есть на самом деле: виджетов здесь нет,
рисуй текстом. Текстовый бар — это `\\r` в stderr, который `stream.py` уже понимает и
превращает в перерисовку строки.

Подменяется не только `tqdm.auto`, но и любой уже импортированный модуль, забравший бар
себе (`from tqdm.auto import tqdm` в чужом пакете — именно такая ссылка): при подключении
к живому ядру потребитель импортирован раньше нас.
"""

from __future__ import annotations

TEXT_TQDM_SOURCE = '''
def __jupyter_nvim_text_tqdm():
    import sys
    from importlib.util import find_spec

    if find_spec("tqdm") is None:
        return
    import tqdm.auto
    from tqdm.std import tqdm as std_tqdm, trange as std_trange

    # тот же класс, по которому tqdm.auto решал сам: он есть и когда выбран текстовый
    notebook_tqdm = getattr(tqdm.auto, "notebook_tqdm", std_tqdm)
    if notebook_tqdm is std_tqdm:
        return  # ipywidgets в ядре нет, бар и так текстовый

    for module in list(sys.modules.values()):
        bar = getattr(module, "tqdm", None)
        if isinstance(bar, type) and issubclass(bar, notebook_tqdm):
            try:
                module.tqdm = std_tqdm
                if getattr(module, "trange", None) is not None:
                    module.trange = std_trange
            except Exception:
                pass


try:
    __jupyter_nvim_text_tqdm()
except Exception:
    pass
finally:
    del __jupyter_nvim_text_tqdm
'''
"""Код скрытой ячейки. Молчит при любом исходе: ядро не должно падать из-за косметики."""
