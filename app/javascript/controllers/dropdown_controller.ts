import { Controller } from '@hotwired/stimulus';

export default class DropdownController extends Controller {
  static targets = ['menu'];

  declare menuTarget: HTMLElement;
  declare hasMenuTarget: boolean;

  private boundClose!: (event: Event) => void;

  connect(): void {
    this.boundClose = this.closeOutside.bind(this);
    document.addEventListener('click', this.boundClose);
  }

  disconnect(): void {
    document.removeEventListener('click', this.boundClose);
  }

  toggle(): void {
    if (!this.hasMenuTarget) return;

    this.menuTarget.classList.toggle('hidden');
  }

  private closeOutside(event: Event): void {
    if (!this.hasMenuTarget) return;
    if (this.menuTarget.classList.contains('hidden')) return;

    if (!this.element.contains(event.target as Node)) {
      this.menuTarget.classList.add('hidden');
    }
  }
}
