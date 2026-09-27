import * as React from "react";
import { createFileRoute } from "@tanstack/react-router";

import { ViewLoadingFallback } from "@/shared/ui/ViewLoadingFallback";

const AgentSessionsScreen = React.lazy(async () => {
  const module = await import("@/features/agents/ui/AgentSessionsScreen");
  return { default: module.AgentSessionsScreen };
});

export const Route = createFileRoute("/sessions")({
  component: SessionsRouteComponent,
});

function SessionsRouteComponent() {
  return (
    <React.Suspense fallback={<ViewLoadingFallback kind="agents" />}>
      <AgentSessionsScreen />
    </React.Suspense>
  );
}
