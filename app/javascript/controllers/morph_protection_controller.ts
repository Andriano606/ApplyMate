import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  connect(): void {
    this.preventMorph = this.preventMorph.bind(this);
    document.addEventListener('turbo:before-morph-element', this.preventMorph);
  }

  disconnect(): void {
    document.removeEventListener(
      'turbo:before-morph-element',
      this.preventMorph,
    );
  }

  preventMorph(event: Event): void {
    const customEvent = event as CustomEvent;

    if (this.element !== customEvent.target) return;

    // Only block the morph when the incoming element still has a model-viewer
    // (GLB is ready). If the server returned a different state (e.g. pending
    // spinner after a color change), allow the morph so the UI updates.
    const newElement = customEvent.detail?.newElement as Element | undefined;
    if (
      !newElement ||
      newElement.querySelector('[data-controller~="model-viewer"]')
    ) {
      customEvent.preventDefault();
    }
  }
}
