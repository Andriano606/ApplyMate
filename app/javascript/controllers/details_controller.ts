import { Controller } from '@hotwired/stimulus';

/**
 * A <details> disclosure with a cancel button: focuses the `focus` target when
 * opened and closes on `details#close`.
 */
export default class extends Controller<HTMLDetailsElement> {
  static targets = ['focus'];

  declare readonly hasFocusTarget: boolean;
  declare readonly focusTarget: HTMLElement;

  connect(): void {
    this.element.addEventListener('toggle', this.onToggle);
  }

  disconnect(): void {
    this.element.removeEventListener('toggle', this.onToggle);
  }

  close(): void {
    this.element.open = false;
  }

  private onToggle = (): void => {
    if (this.element.open && this.hasFocusTarget) this.focusTarget.focus();
  };
}
