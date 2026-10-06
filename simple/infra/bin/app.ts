#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { SimpleAguiStack } from "../lib/simple-agui-stack";

const app = new cdk.App();

new SimpleAguiStack(app, "SimpleAguiStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: "us-east-1",
  },
  description: "Simple iOS chat sample with an agent on Bedrock AgentCore Runtime",
});
