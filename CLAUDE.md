# CLAUDE.md

AgenticNotch で作業するときのガイドです。`~/CLAUDE.md`（グローバル）の指示に加えて、このリポジトリでは以下に従ってください。

## このリポジトリの位置づけ

boring.notch から 2 段フォークした、個人カスタマイズ用のリポジトリです。

| リモート | リポジトリ | 位置づけ |
|---|---|---|
| `origin` | hannaheptapod/AgenticNotch | このリポジトリ。作業対象 |
| `upstream` | lucasscurtoo/AgenticNotch | フォーク元。AI エージェント通知機能の originator |
| `boringnotch` | TheBoredTeam/boring.notch | 元祖。music / calendar / shelf などの本体 |

**上流に PR を出す予定はありません。** フォーク内で完結させる前提でルールを決めています。上流へ貢献する場合のみ `CONTRIBUTING.md` の規約（`dev` ベース・`feature/*` 命名・PR base は `dev`）に従ってください。

## ブランチ戦略（GitHub Flow）

Git Flow ではありません。ソロ開発で CI もリリース審査もないため、`develop` は挟みません。

```
main            常に動く状態を保つ唯一の幹。origin のデフォルトブランチ
<topic>/<name>  main から分岐し、main へマージして削除する短命ブランチ
upstream-main   lucasscurtoo/AgenticNotch のミラー。ここでは絶対に作業しない
```

### ブランチ名のプレフィックス

`feature/` `fix/` `refactor/` `docs/` `chore/` の 5 種のみ使います。小文字・数字・ハイフンのみ（例 `feature/codex-live-activity`、`fix/notch-text-truncation`）。

`claude/` `agent/` `temp/` などが付いていたら、作業を始める前に `git branch -m <旧名> <新名>` で改名してください。

### 作業開始前の確認

1. `git branch --show-current` で現在地を確認する
2. `main` にいる場合は、**編集を始める前に**トピックブランチを切る
3. `upstream-main` にいる場合は絶対に編集しない。`git switch main` してから切り直す
4. 規定のトピックブランチ上ならそのまま続行する

ただし**タイポ修正やドキュメントの一行直しなど、レビューの余地がない些細な変更は `main` に直接コミットして構いません。** ソロのフォークで PR を経由する価値がないものにまで手順を課さないでください。

### マージ

セルフマージなので PR は必須ではありません。まとまった変更や後から経緯を追いたい変更のみ PR を作ります。PR を作った場合、**マージはユーザーが行います。Claude は自律的にマージしません。**

## コミット規約

- **コミット・push はユーザーから明示的に依頼されたときのみ行う。** 実装が終わっても勝手にコミットしない
- 1 コミット 1 論点。無関係な変更を混ぜない。1 回の作業で複数の論点に触れたら、ハンク単位で分けてコミットする
- メッセージは英語・命令形・sentence case。`feat:` `fix:` などの Conventional Commits プレフィックスは**使わない**（このフォークの既存履歴に合わせる。上流 boring.notch は使っているので混同しないこと）
- 本文には「何をしたか」ではなく**「なぜそうしたか」**を書く。数値の根拠、却下した代替案、既知の制約を残す
- 末尾に `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` を付ける

## 上流との同期

```bash
git fetch upstream boringnotch
git switch upstream-main && git merge --ff-only upstream/main   # ミラーを進める
git switch main && git merge upstream-main                       # 取り込みは main で
```

取り込みは独立したコミットとして行い、自分の変更と混ぜないでください。`boringnotch/main` から直接取り込む場合も同様です。

## やらないこと

- `main` への force push、`git reset --hard`、タグの push
- `boringNotch.xcodeproj/project.pbxproj` の署名設定の変更（フォークの差分を機能に限定するため。署名はビルド時フラグで渡す。[scripts/install-local.sh](scripts/install-local.sh) 参照）
- 上流由来のファイル（`CONTRIBUTING.md`・`LICENSE`・`crowdin.yml` 等）の書き換え

## ビルドとインストール

```bash
./scripts/install-local.sh
```

ビルド・署名・`/Applications` への入れ替え・再起動をまとめて行います。

**`xcodebuild` を直接叩いたり Xcode の GUI からビルドしたものを手で入れ替えないでください。** プロジェクトは macOS 向けに ad-hoc 署名（`CODE_SIGN_IDENTITY[sdk=macosx*] = "-"`）で、指定要件が cdhash になります。ハッシュはビルドのたびに変わるため、TCC が別アプリとみなしてプライバシー権限が毎回リセットされます。スクリプトは安定した証明書で署名してこれを回避します。
