"""Картинки matplotlib вдвое плотнее: retina по умолчанию. README, «Images».

image.nvim рисует png пиксель в пиксель. Дефолтные 100 dpi matplotlib на HiDPI-экране —
это график на треть окна вывода, где подписи осей едва читаются. `retina` отдаёт png с
удвоенным разрешением, и физический размер на экране выходит таким же, как в Jupyter Lab.

Включается через конфиг шелла, а не `%config`: на старте ядра matplotlib ещё не
импортирован, `InlineBackend` не существует, и магия падает с ошибкой. Конфиг же
подхватывается, когда бэкенд создаётся при первом графике (проверено на ipykernel 7 и
matplotlib-inline: 1×1 дюйм — 117×122 px без него, 234×244 с ним). Свой `%config
InlineBackend.figure_format = ...` в ноутбуке по-прежнему главнее: он ставится позже.
"""

from __future__ import annotations

RETINA_SOURCE = '''
try:
    get_ipython().config.InlineBackend.figure_formats = {"retina"}
except Exception:
    pass
'''
"""Код скрытой ячейки. Молчит при любом исходе: ядро не должно падать из-за косметики."""
