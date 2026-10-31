import { httpRouter } from "convex/server";
import { authComponent, createAuth } from "./betterAuth/auth";

const http = httpRouter();

// Serves Better Auth at https://<deployment>.convex.site/api/auth/*
authComponent.registerRoutes(http, createAuth);

export default http;
