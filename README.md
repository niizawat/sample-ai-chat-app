# iOS × Bedrock AgentCore チャットサンプル

Amazon Bedrock AgentCore Runtime 上のエージェントと、
SwiftUI の iOS アプリから会話するサンプル集です。

各ディレクトリに独立した構成（エージェント / CDK / iOS）があります。
手順・前提条件・デプロイ方法は、各サンプルの README を参照してください。

## サンプル一覧

| ディレクトリ | 概要 |
| --- | --- |
| [`simple/`](simple/) | 最小構成チャット |
| [`push-event/`](push-event/) | クラウド側で発生したイベントを通知してチャットを開始する |

### simple

- Cognito サインイン
- AgentCore Runtime への JWT 付き呼び出し
- SSE によるストリーミング応答

詳細: [simple/README.md](simple/README.md)

### push-event

- simple の構成に加え、SNS → FCM のプッシュ通知
- 通知タップ時は DynamoDB に保存した文面を LLM なしで表示

詳細: [push-event/README.md](push-event/README.md)

## 共通事項

- リージョン: `us-east-1`
- クライアント: SwiftUI（iOS 17 以上）
- バックエンド: Bedrock AgentCore Runtime
- 認証: Amazon Cognito（JWT Bearer）
- IaC: AWS CDK（TypeScript） / パッケージ管理は pnpm
