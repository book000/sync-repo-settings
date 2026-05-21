# GitHub Copilot Instructions

## プロジェクト概要

- 目的: 複数の GitHub リポジトリの設定を一括で同期・管理する
- 主な機能: リポジトリ基本設定、ワークフロー権限、Actions 変数、ルールセット、Copilot レビュー設定の自動適用
- 対象ユーザー: リポジトリ管理者

## 共通ルール

- 会話は日本語で行う
- PR とコミットは [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) に従う（`<description>` は日本語）
- 日本語と英数字の間には半角スペースを入れる
- コード内コメントは日本語で記載する
- エラーメッセージは英語で記載する

## 技術スタック

- 言語: Bash
- 依存ツール: `gh` CLI, `jq`
- 実行環境: GitHub Actions, ローカル

## コーディング規約

- `set -euo pipefail` を使用してエラー処理を厳密にする
- 変数は `"$VAR"` のようにダブルクォートで囲む
- 関数内では `local` を使用してスコープを限定する
- API レスポンスのエラーハンドリングを必ず行う

## 開発コマンド

```bash
# ドライラン（実際には適用しない）
./apply-settings.sh --dry-run

# 特定オーナーのみ処理
./apply-settings.sh --target tomacheese

# 特定リポジトリのみ処理
./apply-settings.sh --repo tomacheese/my-repo

# Markdown 形式で出力（PR コメント用）
./apply-settings.sh --dry-run --markdown

# 詳細ログ
./apply-settings.sh --verbose
```

## テスト方針

- `--dry-run` オプションで適用内容を事前確認する
- 特定リポジトリで動作確認後、全体に適用する
- PR 作成時は自動で dry-run プレビューがコメントされる

## セキュリティ / 機密情報

- `PERSONAL_ACCESS_TOKEN` は Repository Secrets で管理する
- トークンをログに出力しない
- `gh auth token` の結果をコミットしない

## ドキュメント更新

- `apply-settings.sh`: コマンドライン引数や機能追加時にヘルプメッセージを更新
- `config.json`: 設定スキーマの変更時にプロンプトファイル内の構造説明を更新
- 各プロンプトファイル (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`): プロジェクトのルール変更時に同期して更新

## リポジトリ固有

- `config.json` でフィルタルールを定義し、フォークリポジトリやアーカイブ済みリポジトリを除外する
- ステータスチェックは PR トリガーのワークフローから自動検出する
- `finished-*` ジョブがある場合はそちらを優先する
