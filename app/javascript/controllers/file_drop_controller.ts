import { Controller } from '@hotwired/stimulus';

export default class FileDropController extends Controller {
  static targets = ['dropZone', 'input', 'label'];

  declare dropZoneTarget: HTMLElement;
  declare inputTarget: HTMLInputElement;
  declare labelTarget: HTMLElement;

  private originalLabelText: string = '';

  connect(): void {
    this.originalLabelText = this.labelTarget.textContent || '';
  }

  dragOver(event: DragEvent): void {
    event.preventDefault();
    this.dropZoneTarget.classList.add(
      'border-indigo-500',
      'bg-indigo-50',
      'dark:bg-indigo-900/20',
    );
  }

  dragLeave(event: DragEvent): void {
    event.preventDefault();
    this.removeHighlight();
  }

  drop(event: DragEvent): void {
    event.preventDefault();
    this.removeHighlight();

    const files = event.dataTransfer?.files;
    if (files && files.length > 0) {
      this.inputTarget.files = files;
      this.updateLabel(files);
      this.inputTarget.dispatchEvent(new Event('change', { bubbles: true }));
    }
  }

  openFileDialog(): void {
    this.inputTarget.click();
  }

  fileSelected(): void {
    const files = this.inputTarget.files;
    if (files && files.length > 0) {
      this.updateLabel(files);
    }
  }

  private removeHighlight(): void {
    this.dropZoneTarget.classList.remove(
      'border-indigo-500',
      'bg-indigo-50',
      'dark:bg-indigo-900/20',
    );
  }

  private updateLabel(files: FileList): void {
    this.labelTarget.textContent = Array.from(files)
      .map((f) => f.name)
      .join(', ');
    this.labelTarget.classList.add(
      'text-indigo-600',
      'dark:text-indigo-400',
      'font-medium',
    );
  }
}
