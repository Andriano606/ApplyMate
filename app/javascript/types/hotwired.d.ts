declare module '@hotwired/turbo' {
  export interface StreamActions {
    [key: string]: (this: Element) => void;
  }
  export const StreamActions: StreamActions;
  export function renderStreamMessage(message: string): void;
}

declare module '@rails/ujs' {
  const Rails: {
    csrfToken(): string;
  };
  export default Rails;
}

declare module '@hotwired/turbo-rails' {
  export const Turbo: {
    visit(url: string, options?: { action?: string; frame?: string }): void;
    clearCache(): void;
    setProgressBarDelay(delay: number): void;
    connectStreamSource(source: EventSource | WebSocket): void;
    disconnectStreamSource(source: EventSource | WebSocket): void;
  };
}
