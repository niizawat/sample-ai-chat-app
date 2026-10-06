import * as path from "path";
import * as cdk from "aws-cdk-lib";
import * as bedrockagentcore from "aws-cdk-lib/aws-bedrockagentcore";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as ecrAssets from "aws-cdk-lib/aws-ecr-assets";
import * as iam from "aws-cdk-lib/aws-iam";
import { Construct } from "constructs";

const BEDROCK_MODEL_ID = "us.openai.gpt-6.1-sol";

export class SimpleAguiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const userPool = new cognito.UserPool(this, "UserPool", {
      userPoolName: `${this.stackName}-users`,
      selfSignUpEnabled: false,
      signInAliases: { username: true },
      passwordPolicy: {
        minLength: 8,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: false,
      },
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const userPoolClient = userPool.addClient("UserPoolClient", {
      userPoolClientName: `${this.stackName}-ios-client`,
      generateSecret: false,
      authFlows: {
        userPassword: true,
        userSrp: true,
      },
    });

    const agentImage = new ecrAssets.DockerImageAsset(this, "AgentImage", {
      directory: path.join(__dirname, "../../agent"),
      platform: ecrAssets.Platform.LINUX_ARM64,
    });

    const agentRuntimeName = `${this.stackName.replace(/-/g, "_")}_AguiAgent`;

    const agentRole = new iam.Role(this, "AgentRuntimeRole", {
      assumedBy: new iam.ServicePrincipal("bedrock-agentcore.amazonaws.com", {
        conditions: {
          StringEquals: { "aws:SourceAccount": this.account },
          ArnLike: {
            "aws:SourceArn": `arn:aws:bedrock-agentcore:${this.region}:${this.account}:*`,
          },
        },
      }),
      inlinePolicies: {
        AgentCoreExecutionPolicy: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              sid: "ECRImageAccess",
              actions: ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
              resources: [agentImage.repository.repositoryArn],
            }),
            new iam.PolicyStatement({
              sid: "ECRTokenAccess",
              actions: ["ecr:GetAuthorizationToken"],
              resources: ["*"],
            }),
            new iam.PolicyStatement({
              sid: "CloudWatchLogs",
              actions: [
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams",
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
              ],
              resources: [
                `arn:aws:logs:${this.region}:${this.account}:log-group:/aws/bedrock-agentcore/runtimes/*`,
                `arn:aws:logs:${this.region}:${this.account}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*`,
              ],
            }),
            new iam.PolicyStatement({
              sid: "XRay",
              actions: [
                "xray:PutTraceSegments",
                "xray:PutTelemetryRecords",
                "xray:GetSamplingRules",
                "xray:GetSamplingTargets",
              ],
              resources: ["*"],
            }),
            new iam.PolicyStatement({
              sid: "CloudWatchMetrics",
              actions: ["cloudwatch:PutMetricData"],
              resources: ["*"],
              conditions: {
                StringEquals: { "cloudwatch:namespace": "bedrock-agentcore" },
              },
            }),
            // JWT 認証のみ。GetWorkloadAccessTokenForUserId は付与しない。
            new iam.PolicyStatement({
              sid: "WorkloadAccessTokenJwtOnly",
              actions: [
                "bedrock-agentcore:GetWorkloadAccessToken",
                "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
              ],
              resources: [
                `arn:aws:bedrock-agentcore:${this.region}:${this.account}:workload-identity-directory/default`,
                `arn:aws:bedrock-agentcore:${this.region}:${this.account}:workload-identity-directory/default/workload-identity/${agentRuntimeName}-*`,
              ],
            }),
            new iam.PolicyStatement({
              sid: "InvokeGpt61SolOnly",
              actions: [
                "bedrock:InvokeModel",
                "bedrock:InvokeModelWithResponseStream",
              ],
              resources: [
                `arn:aws:bedrock:${this.region}:${this.account}:inference-profile/${BEDROCK_MODEL_ID}`,
                "arn:aws:bedrock:*::foundation-model/openai.gpt-6.1-sol",
              ],
            }),
            // 第三者モデルの初回自動購読に必要（購読完了後はアカウント全体で利用可能）。
            new iam.PolicyStatement({
              sid: "MarketplaceModelSubscription",
              actions: [
                "aws-marketplace:ViewSubscriptions",
                "aws-marketplace:Subscribe",
                "aws-marketplace:Unsubscribe",
              ],
              resources: ["*"],
            }),
          ],
        }),
      },
    });

    const discoveryUrl = `https://cognito-idp.${this.region}.amazonaws.com/${userPool.userPoolId}/.well-known/openid-configuration`;

    const agentRuntime = new bedrockagentcore.CfnRuntime(this, "AguiAgentRuntime", {
      agentRuntimeName,
      description: "Sample chat agent on AgentCore Runtime using GPT-6.1 Sol",
      roleArn: agentRole.roleArn,
      agentRuntimeArtifact: {
        containerConfiguration: {
          containerUri: agentImage.imageUri,
        },
      },
      networkConfiguration: {
        networkMode: "PUBLIC",
      },
      protocolConfiguration: "AGUI",
      environmentVariables: {
        AWS_REGION: this.region,
        AWS_DEFAULT_REGION: this.region,
        BEDROCK_MODEL_ID,
      },
      authorizerConfiguration: {
        customJwtAuthorizer: {
          discoveryUrl,
          allowedClients: [userPoolClient.userPoolClientId],
        },
      },
      requestHeaderConfiguration: {
        requestHeaderAllowlist: ["Authorization"],
      },
    });

    agentRuntime.node.addDependency(agentRole);

    new cdk.CfnOutput(this, "AgentRuntimeArn", {
      value: agentRuntime.attrAgentRuntimeArn,
      description: "Bedrock AgentCore Runtime ARN for the chat agent",
    });
    new cdk.CfnOutput(this, "UserPoolId", {
      value: userPool.userPoolId,
    });
    new cdk.CfnOutput(this, "UserPoolClientId", {
      value: userPoolClient.userPoolClientId,
    });
    new cdk.CfnOutput(this, "AwsRegion", {
      value: this.region,
    });
    new cdk.CfnOutput(this, "BedrockModelId", {
      value: BEDROCK_MODEL_ID,
    });
  }
}
