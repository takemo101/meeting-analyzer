# 話者判断の評価（合成）

`meeting-analyzer actors try --cases` で、話者の判断（SPEC §3.13）の工夫を、同じ入力で比べるための、**合成した**データ。実在の人・会議とは関係ありません。**会議の本文は、置きません**（実会議の文字起こしは、コミットしない）。

| ファイル | 内容 |
|---|---|
| `actors-nouns.md` | 架空の 10 人。役割は短く、話題は語（API・データベースなど） |
| `actors-phrases.md` | 同じ 10 人。話題を、言いそうな言い方（「レスポンスが遅い」など）にしたもの |
| `cases.jsonl` | 100 件（160 文）。1 件は、確定した発話 1 つ＝文を話した順に並べたもの。各文に、正解の話者（`null`＝付けないのが正解） |

`tag`：`single`（1 文）・`run`（同じ話者の 2 文）・`turn`（話者が替わる 2 文）・`turn3`（A・A・B）・`filler`（相づち）。

```sh
# 判断モデルを取得して（約 1.2 GB）、2 つの単位を比べる
meeting-analyzer models download tiny-jev-0.6b
meeting-analyzer actors try eval/actors-nouns.md --judge tiny-jev-0.6b --unit both --cases eval/cases.jsonl
```

結果（正解・**確信して間違い**・付けなかった・1 件あたりの秒）は、[検証記録](../docs/verification.md)。サンプルが小さく、私が作った文なので、**方向を見るため**のものです。
