import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  static targets = ['input', 'preview', 'placeholder'];

  declare inputTarget: HTMLInputElement;
  declare previewTarget: HTMLImageElement;
  declare placeholderTarget: HTMLElement;
  declare hasPlaceholderTarget: boolean;

  display() {
    const file = this.inputTarget.files?.[0];
    if (!file) return;

    const reader = new FileReader();

    reader.onload = (e) => {
      this.previewTarget.src = e.target!.result as string;
      this.previewTarget.classList.remove('hidden');

      if (this.hasPlaceholderTarget) {
        this.placeholderTarget.classList.add('hidden');
      }
    };

    reader.readAsDataURL(file);
  }
}
