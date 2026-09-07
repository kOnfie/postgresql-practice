# notes/ — твої конспекти

Головна вправа всього курсу: **пояснити механізм своїми словами**. Якщо не виходить написати — ти це не зрозумів.

## Що сюди класти

- `NN-checkpoint.md` — відповіді на контрольні питання в кінці кожного підплану (`plan/NN-*.md`). Без підглядання, потім звірка.
- `NN-<тема>.md` — розбір конкретних вправ, спостереження з `EXPLAIN`, «моя модель того, як це працює».
- Коли просиш поглиблений підплан — Claude кладе його в `plan/deep-NN-<тема>.md`, а твої нотатки й діалог-перевірка — сюди.

## Ритуал перевірки себе (після кожної теми)

1. «Опа, це цікаво» → попроси поглиблений підплан.
2. «Здається, не до кінця розумію» → напиши сюди свою версію, попроси Claude підтвердити/спростувати прикладами на `shop`.
3. «Нудно й очевидно» → все одно 2–3 вправи, щоб закріпити синтаксис.

## Файли (створюй по мірі проходження)

```
01-schema-map.md  01-types.md  01-constraints.md  01-checkpoint.md
02-null.md  02-joins.md  02-checkpoint.md
03-checkpoint.md
04-denorm.md  04-er.md  04-design.md  04-checkpoint.md
05-isolation.md  05-mvcc.md  05-checkout.md  05-checkpoint.md
06-composite.md  06-no-index.md  06-jsonb-idx.md  06-checkpoint.md
07-nodes/  07-stats.md  07-costs.md  07-explain-cases.md  07-checkpoint.md
08-checkpoint.md
09-checkpoint.md
10-partitioning.md  10-checkpoint.md
11-checkpoint.md
cv-bullets.md
```
