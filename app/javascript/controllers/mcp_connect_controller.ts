import { Controller } from '@hotwired/stimulus';
import * as Turbo from '@hotwired/turbo';
import { railsFetch } from '../util/rails_fetch';

/**
 * "Connect Claude (MCP)" modal: one click copies the `claude mcp add …` command.
 *
 * When the user has no token yet (empty `command` value) the click POSTs to
 * `createUrl`, which creates the token and answers with the re-rendered modal as
 * a Turbo Stream. The command is read out of that stream and handed to the
 * clipboard as a promise (ClipboardItem), so the copy still counts as part of
 * the click in Safari and Firefox; the stream is then rendered so the modal
 * shows the token and the regenerate button.
 */
export default class extends Controller {
  static targets = ['label'];
  static values = {
    command: String,
    createUrl: String,
    copiedLabel: String,
    failedLabel: String,
  };

  declare readonly labelTarget: HTMLElement;
  declare commandValue: string;
  declare readonly createUrlValue: string;
  declare readonly copiedLabelValue: string;
  declare readonly failedLabelValue: string;

  private resetTimer?: number;

  async copy(): Promise<void> {
    let copied: Promise<void>;
    let rendered: Promise<void> = Promise.resolve();

    if (this.commandValue) {
      copied = this.writeClipboard(this.commandValue);
    } else {
      const stream = this.createToken();
      copied = this.writeClipboard(
        stream.then((html) => this.commandFrom(html)),
      );
      // Rendered even when the clipboard refuses (permission denied, plain
      // http): the token now exists and the modal must show its command so
      // it can be copied by hand.
      rendered = stream.then((html) => Turbo.renderStreamMessage(html));
    }

    const [render, copy] = await Promise.allSettled([rendered, copied]);
    if (render.status === 'rejected')
      console.error('MCP token request failed', render.reason);
    if (copy.status === 'rejected')
      console.error('MCP command copy failed', copy.reason);
    this.flashLabel(
      copy.status === 'fulfilled'
        ? this.copiedLabelValue
        : this.failedLabelValue,
    );
  }

  private async createToken(): Promise<string> {
    const response = await railsFetch(this.createUrlValue, {
      method: 'POST',
      headers: { Accept: 'text/vnd.turbo-stream.html' },
    });
    if (!response.ok)
      throw new Error(`token request failed: ${response.status}`);

    return response.text();
  }

  private commandFrom(streamHtml: string): string {
    const doc = new DOMParser().parseFromString(streamHtml, 'text/html');
    for (const template of Array.from(doc.querySelectorAll('template'))) {
      const element = template.content.querySelector<HTMLElement>(
        '[data-mcp-connect-command-value]',
      );
      const command = element?.dataset.mcpConnectCommandValue;
      if (command) return command;
    }
    throw new Error('no command in the response');
  }

  // async so a missing navigator.clipboard (insecure context) rejects instead of throwing.
  private async writeClipboard(text: string | Promise<string>): Promise<void> {
    if (typeof text === 'string') {
      await navigator.clipboard.writeText(text);
    } else if (
      typeof ClipboardItem !== 'undefined' &&
      navigator.clipboard.write
    ) {
      const blob = text.then(
        (value) => new Blob([value], { type: 'text/plain' }),
      );
      await navigator.clipboard.write([
        new ClipboardItem({ 'text/plain': blob }),
      ]);
    } else {
      await navigator.clipboard.writeText(await text);
    }
  }

  private flashLabel(text: string): void {
    // Looked up after the stream render: the morph may have replaced the label.
    const label = this.labelTarget;
    const original = label.dataset.originalText ?? label.textContent ?? '';
    label.dataset.originalText = original;
    label.textContent = text;
    window.clearTimeout(this.resetTimer);
    this.resetTimer = window.setTimeout(() => {
      label.textContent = original;
      delete label.dataset.originalText;
    }, 2000);
  }
}
