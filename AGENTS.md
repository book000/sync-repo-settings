# AGENTS.md

## 目的

このファイルは AI エージェント共通の作業方針を定義します。

## 基本方針

### 言語

- 会話言語: 日本語
- コード内コメント: 日本語
- エラーメッセージ: 英語
- 日本語と英数字の間: 半角スペースを挿入

### コミット規約

- [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) に従う
- `<description>` は日本語で記載
- 例: `feat: フィルタルールを追加`

## 判断記録のルール

重要な判断を行う際は、以下を明示的に記録すること:

1. 判断内容の要約
2. 検討した代替案
3. 採用しなかった案とその理由
4. 前提条件・仮定・不確実性
5. 他エージェントによるレビュー可否

前提・仮定・不確実性を明示し、仮定を事実のように扱わないこと。

## プロジェクト概要

- 目的: 複数の GitHub リポジトリの設定を一括で同期・管理する
- 主な機能:
  - リポジトリ基本設定の適用
  - ワークフロー権限の設定
  - Actions 変数の設定
  - ルールセットの作成・更新
  - Copilot Code Review の有効化

## 開発手順

1. **プロジェクト理解**
   - `config.json` の構造を確認
   - `apply-settings.sh` の処理フローを理解

2. **環境確認**
   - `gh` CLI がインストールされ、認証されていることを確認
   - `jq` がインストールされていることを確認

3. **変更実装**
   - `config.json` の設定を変更
   - 必要に応じて `apply-settings.sh` を修正

4. **動作確認**
   - `./apply-settings.sh --dry-run` で変更内容を確認
   - 特定リポジトリで `--repo` オプションを使ってテスト

5. **コミット・プッシュ**
   - Conventional Commits に従ったコミットメッセージを作成
   - センシティブな情報が含まれていないことを確認

## 開発コマンド

```bash
# ドライラン
./apply-settings.sh --dry-run

# 特定オーナーのみ
./apply-settings.sh --target tomacheese

# 特定リポジトリのみ
./apply-settings.sh --repo tomacheese/my-repo

# Markdown 出力
./apply-settings.sh --dry-run --markdown

# 詳細ログ
./apply-settings.sh --verbose
```

## セキュリティ / 機密情報

- `PERSONAL_ACCESS_TOKEN` は Repository Secrets で管理する
- トークンをログやコミットに含めない
- API レスポンスに含まれる機密情報を出力しない

## リポジトリ固有

- `config.json` でターゲットオーナーとフィルタルールを定義する
- GitHub Actions で毎日定期実行される
- PR 作成時は自動で dry-run プレビューがコメントされる
