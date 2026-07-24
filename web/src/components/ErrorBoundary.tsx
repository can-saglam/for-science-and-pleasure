import { Component, type ErrorInfo, type ReactNode } from "react";
import { Button } from "@/components/ui/button";

type Props = { children: ReactNode };
type State = { error: Error | null };

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("App crashed", error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;

    return (
      <div className="flex min-h-dvh flex-col items-center justify-center gap-4 px-6 text-center">
        <div className="space-y-2">
          <h1 className="font-heading text-2xl font-semibold tracking-tight">
            Something went wrong
          </h1>
          <p className="max-w-sm text-sm text-muted-foreground">
            The app hit an unexpected error. Reloading usually fixes it — your
            saves are safe.
          </p>
        </div>
        <Button
          onClick={() => {
            this.setState({ error: null });
            window.location.reload();
          }}
        >
          Reload
        </Button>
      </div>
    );
  }
}
