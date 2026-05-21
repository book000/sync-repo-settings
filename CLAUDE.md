# CLAUDE.md

## 目的

このファイルは Claude Code の作業方針とプロジェクト固有のルールを定義します。

## 基本的なルール

- 判断は必ずレビュー可能な形で記録すること
  1. 判断内容の要約
  2. 検討した代替案
  3. 採用しなかった案とその理由
  4. 前提条件・仮定・不確実性
  5. 他エージェントによるレビュー可否
- 前提・仮定・不確実性を明示すること。仮定を事実のように扱ってはならない

## プロジェクト概要

- 目的: 複数の GitHub リポジトリの設定を一括で同期・管理する
- 主な機能:
  - リポジトリ基本設定（マージ方法、自動削除など）の適用
  - ワークフロー権限の設定
  - Actions 変数（Copilot Firewall 等）の設定
  - ルールセットの作成・更新
  - Copilot Code Review の有効化
- 対象: tomacheese, book000 配下のリポジトリ

## 重要ルール

### 言語

- 会話言語: 日本語
- コード内コメント: 日本語
- エラーメッセージ: 英語
- 日本語と英数字の間: 半角スペースを挿入

### コミット規約

- [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) に従う
- `<description>` は日本語で記載
- 例: `feat: フィルタルールを追加`

### ブランチ命名

- [Conventional Branch](https://conventional-branch.github.io) に従う
- `<type>` は短縮形（feat, fix）を使用
- 例: `feat/add-filter-rule`

## 環境のルール

- Renovate が作成した既存の PR に対して、追加コミットや更新を行ってはならない
- GitHub リポジトリを調査のために参照する場合、テンポラリディレクトリに git clone して検索する
- プロジェクトによっては、Git Worktree を採用している場合がある。その場合、ディレクトリ構成は以下とする
  - `.bare/` (bare リポジトリ)
  - `<ブランチ名>/` (worktree)

## コード改修時のルール

- 日本語と英数字の間には、半角スペースを挿入する
- 既存のエラーメッセージで先頭に絵文字がある場合は、全体でエラーメッセージに絵文字を設定する。絵文字はエラーメッセージに即した一文字とする
- `set -euo pipefail` を使用してエラー処理を厳密にする
- 変数は `"$VAR"` のようにダブルクォートで囲む
- 関数内では `local` を使用してスコープを限定する（ただしトップレベルでは使用しない）
- API レスポンスのエラーハンドリングを必ず行う
- `jq` のエラーを適切にハンドリングする
- シェルスクリプトの各関数には、用途、引数、戻り値を日本語でコメント（docstring 形式）として記載する

## 相談ルール

### Codex CLI (ask-codex)

- 実装コードに対するソースコードレビュー
- シェルスクリプトの設計、エラーハンドリング方針

### Gemini CLI (ask-gemini)

- GitHub API の最新仕様確認
- gh CLI の使用方法確認

### 指摘への対応

他エージェントが指摘・異議を提示した場合、必ず以下のいずれかを行う（黙殺禁止）:

- 指摘を受け入れ、判断を修正する
- 指摘を退け、その理由を明示する

## 開発コマンド

```bash
# ドライラン（実際には適用しない）
./apply-settings.sh --dry-run

# 全ターゲットに適用
./apply-settings.sh

# 特定オーナーのみ処理
./apply-settings.sh --target tomacheese

# 特定リポジトリのみ処理
./apply-settings.sh --repo tomacheese/my-repo

# Markdown 形式で出力（PR コメント用）
./apply-settings.sh --dry-run --markdown

# 詳細ログ
./apply-settings.sh --verbose
```

## アーキテクチャと主要ファイル

```
sync-repo-settings/
├── .github/
│   └── workflows/
│       ├── sync.yml           # 定期実行ワークフロー（毎日 AM 9:00 JST）
│       └── pr-preview.yml     # PR 時の dry-run プレビュー
├── apply-settings.sh          # メイン適用スクリプト
├── config.json                # 設定ファイル（ターゲット、デフォルト設定、フィルタルール）
├── CLAUDE.md                  # Claude Code 向け指示
├── AGENTS.md                  # 汎用 AI エージェント向け指示
└── GEMINI.md                  # Gemini CLI 向け指示
```

### config.json の構造

- `targets`: 処理対象のオーナー一覧
- `defaults`: デフォルト設定（各設定項目に `mode` と `values` を持つ）
- `rules`: フィルタルール（条件にマッチしたリポジトリに設定を上書き適用）

### 適用モード

| モード | 動作 |
|--------|------|
| `insert` | 設定がない場合のみ追加 |
| `upsert` | 追加または更新（デフォルト）。既存の設定は上書きされる |
| `skip` | スキップ |

## 実装パターン

- **関数の定義**: 全ての関数は `function_name() { ... }` 形式で定義し、冒頭に docstring を記載する
- **GitHub API 呼び出し**: `gh api` を使用し、`-H "$API_VERSION_HEADER"` を必ず含める
- **設定の読み取り**: `jq` を使用して `config.json` から設定を抽出する

## ドキュメント更新ルール

- `config.json` の構造を変更した場合は、`apply-settings.sh` のヘルプおよびプロンプトファイルの `config.json の構造` セクションを更新する
- 新規機能（コマンドライン引数など）を追加した場合は、`apply-settings.sh` のヘルプおよび各プロンプトファイルの `開発コマンド` セクションを更新する

## テスト方針

- 新機能追加時は `--dry-run` で動作確認する
- 特定リポジトリで動作確認後、全体に適用する
- PR 作成時は自動で dry-run プレビューがコメントされる

## 作業チェックリスト

### 新規改修時

1. プロジェクトについて詳細に探索し理解すること
2. 作業を行うブランチが適切であること
3. 最新のリモートブランチに基づいた新規ブランチであること

### コミット・プッシュ前

1. コミットメッセージが Conventional Commits に従っていること
2. コミット内容にセンシティブな情報が含まれていないこと
3. `--dry-run` で動作確認を行うこと

### PR 作成前

1. PR 作成をユーザーから依頼されていること
2. コミット内容にセンシティブな情報が含まれていないこと
3. コンフリクトする恐れがないこと

### PR 作成後

1. コンフリクトが発生していないこと
2. PR 本文の内容が最新状態を正確に反映していること
3. `gh pr checks <PR ID> --watch` で GitHub Actions CI を待ち、結果を確認すること

## リポジトリ固有

- `config.json` の `rules` でフィルタルールを定義する
- フォークリポジトリ、アーカイブ済みリポジトリは自動的にスキップされる
- ステータスチェックは PR トリガーのワークフローから自動検出される
- `finished-*` ジョブがある場合はそちらを優先する
- `PERSONAL_ACCESS_TOKEN` は Repository Secrets に設定済み
