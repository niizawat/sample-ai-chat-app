import * as path from "path";
import * as cdk from "aws-cdk-lib";
import * as apigateway from "aws-cdk-lib/aws-apigateway";
import * as bedrockagentcore from "aws-cdk-lib/aws-bedrockagentcore";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as ecrAssets from "aws-cdk-lib/aws-ecr-assets";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as ssm from "aws-cdk-lib/aws-ssm";
import { Construct } from "constructs";

const BEDROCK_MODEL_ID = "us.openai.gpt-6-luna";

export class PushEventStack extends cdk.Stack {
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

    const devicesTable = new dynamodb.Table(this, "DevicesTable", {
      tableName: `${this.stackName}-devices`,
      partitionKey: { name: "username", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const eventsTable = new dynamodb.Table(this, "EventsTable", {
      tableName: `${this.stackName}-events`,
      partitionKey: { name: "username", type: dynamodb.AttributeType.STRING },
      sortKey: { name: "eventId", type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const fcmSecret = new secretsmanager.CfnSecret(this, "FcmServiceAccount", {
      name: `${this.stackName}/fcm-service-account`,
      description:
        "Firebase service account JSON for Amazon SNS FCM platform application",
      secretString: JSON.stringify({
        placeholder: true,
        message: "Replace with Firebase service account JSON",
      }),
    });

    const platformAppParam = new ssm.StringParameter(this, "PlatformAppArnParam", {
      parameterName: `/${this.stackName}/sns-platform-application-arn`,
      stringValue: "PENDING",
      description: "SNS platform application ARN for FCM (created on first device registration)",
    });

    const registerDeviceFn = new lambda.Function(this, "RegisterDeviceFunction", {
      functionName: `${this.stackName}-register-device`,
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(__dirname, "../lambdas/register-device")),
      timeout: cdk.Duration.seconds(30),
      environment: {
        DEVICES_TABLE: devicesTable.tableName,
        FCM_SECRET_ARN: fcmSecret.ref,
        PLATFORM_APP_PARAM: platformAppParam.parameterName,
        PLATFORM_APP_NAME: `${this.stackName}-fcm`,
      },
    });

    devicesTable.grantReadWriteData(registerDeviceFn);
    platformAppParam.grantRead(registerDeviceFn);
    platformAppParam.grantWrite(registerDeviceFn);
    registerDeviceFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ["secretsmanager:GetSecretValue"],
        resources: [fcmSecret.ref, `${fcmSecret.ref}-*`],
      }),
    );
    registerDeviceFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: [
          "sns:CreatePlatformApplication",
          "sns:SetPlatformApplicationAttributes",
          "sns:CreatePlatformEndpoint",
          "sns:SetEndpointAttributes",
          "sns:GetEndpointAttributes",
        ],
        resources: ["*"],
      }),
    );

    const emitEventFn = new lambda.Function(this, "EmitEventFunction", {
      functionName: `${this.stackName}-emit-event`,
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: "index.handler",
      code: lambda.Code.fromAsset(path.join(__dirname, "../lambdas/emit-event")),
      timeout: cdk.Duration.seconds(30),
      environment: {
        DEVICES_TABLE: devicesTable.tableName,
        EVENTS_TABLE: eventsTable.tableName,
      },
    });

    devicesTable.grantReadData(emitEventFn);
    eventsTable.grantWriteData(emitEventFn);
    emitEventFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ["sns:Publish"],
        resources: [
          `arn:aws:sns:${this.region}:${this.account}:endpoint/GCM/*`,
          `arn:aws:sns:${this.region}:${this.account}:app/GCM/*`,
        ],
      }),
    );

    const api = new apigateway.RestApi(this, "DevicesApi", {
      restApiName: `${this.stackName}-devices`,
      description: "Device registration API for push-event sample",
      deployOptions: {
        stageName: "prod",
      },
    });

    const authorizer = new apigateway.CognitoUserPoolsAuthorizer(this, "CognitoAuthorizer", {
      cognitoUserPools: [userPool],
      authorizerName: `${this.stackName}-cognito`,
    });

    const devices = api.root.addResource("devices");
    devices.addMethod(
      "POST",
      new apigateway.LambdaIntegration(registerDeviceFn),
      {
        authorizer,
        authorizationType: apigateway.AuthorizationType.COGNITO,
      },
    );

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
              sid: "InvokeGpt6LunaOnly",
              actions: [
                "bedrock:InvokeModel",
                "bedrock:InvokeModelWithResponseStream",
              ],
              resources: [
                `arn:aws:bedrock:${this.region}:${this.account}:inference-profile/${BEDROCK_MODEL_ID}`,
                "arn:aws:bedrock:*::foundation-model/openai.gpt-6-luna",
              ],
            }),
            new iam.PolicyStatement({
              sid: "MarketplaceModelSubscription",
              actions: [
                "aws-marketplace:ViewSubscriptions",
                "aws-marketplace:Subscribe",
                "aws-marketplace:Unsubscribe",
              ],
              resources: ["*"],
            }),
            new iam.PolicyStatement({
              sid: "EventsTableAccess",
              actions: [
                "dynamodb:GetItem",
                "dynamodb:UpdateItem",
                "dynamodb:Query",
              ],
              resources: [eventsTable.tableArn],
            }),
          ],
        }),
      },
    });

    const discoveryUrl = `https://cognito-idp.${this.region}.amazonaws.com/${userPool.userPoolId}/.well-known/openid-configuration`;

    const agentRuntime = new bedrockagentcore.CfnRuntime(this, "AguiAgentRuntime", {
      agentRuntimeName,
      description: "Push-event chat agent on AgentCore Runtime using GPT-6 Luna",
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
        BEDROCK_MAX_TOKENS: "1024",
        BEDROCK_READ_TIMEOUT: "120",
        AGENT_BUILD_ID: "prebuilt-event-luna-20261006",
        EVENTS_TABLE: eventsTable.tableName,
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
    new cdk.CfnOutput(this, "DevicesApiUrl", {
      value: api.url,
      description: "Base URL for device registration (POST /devices)",
    });
    new cdk.CfnOutput(this, "EmitEventFunctionName", {
      value: emitEventFn.functionName,
      description: "Invoke with aws lambda invoke to emit a push event",
    });
    new cdk.CfnOutput(this, "FcmSecretArn", {
      value: fcmSecret.ref,
      description: "Put Firebase service account JSON into this secret",
    });
    new cdk.CfnOutput(this, "EventsTableName", {
      value: eventsTable.tableName,
    });
    new cdk.CfnOutput(this, "DevicesTableName", {
      value: devicesTable.tableName,
    });
  }
}
