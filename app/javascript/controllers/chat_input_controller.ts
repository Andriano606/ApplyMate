import { Controller } from '@hotwired/stimulus';

export default class ChatInputController extends Controller {
  static targets = ['fileInput', 'fileCount'];

  declare fileInputTarget: HTMLInputElement;
  declare fileCountTarget: HTMLElement;
  declare hasFileCountTarget: boolean;

  openFilePicker(): void {
    this.fileInputTarget.click();
  }

  filesChanged(): void {
    if (!this.hasFileCountTarget) return;
    const count = this.fileInputTarget.files?.length ?? 0;
    this.fileCountTarget.textContent = count > 0 ? String(count) : '';
    this.fileCountTarget.classList.toggle('hidden', count === 0);
  }
}
