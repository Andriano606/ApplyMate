import { Controller } from '@hotwired/stimulus';

export default class TurboModalController extends Controller {
  static targets = ['overlay'];

  declare overlayTarget: HTMLElement;

  private hasChildren() {
    return this.element.hasAttribute('data-child-modal-id');
  }

  close() {
    this.overlayTarget.classList.add('hidden');

    // In the normal case, when a modal is hidden, we remove it from the DOM.
    // This way we can ensure that all connection logic is run again since the element is re-inserted into the HTML if
    // the user initiates a new modal.
    // However, in the case where a modal is hidden because a child element is shown, we cannot remove the element,
    // since we will use client side JavaScript to restore it once the child is hidden.
    // So if the modal has children (is a parent), we will instead just hide it, not remove it.
    if (!this.hasChildren()) {
      this.element.remove(); // No children, remove us from the DOM
    }
    // In any case, we should restore the parent modal when we are hidden:
    // this.restoreHiddenParents()
  }

  closeBackground(event: Event) {
    if (event.target === this.overlayTarget) {
      this.close();
    }
  }
}
