#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { PushEventStack } from "../lib/push-event-stack";

const app = new cdk.App();

new PushEventStack(app, "PushEventStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: "us-east-1",
  },
  description:
    "iOS chat sample with AgentCore Runtime and SNS→FCM push-started conversations",
});
