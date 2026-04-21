import { Controller } from '@hotwired/stimulus';

export default class ChatPanelController extends Controller {
  static targets = ['panel', 'backdrop', 'frame'];
  static values = { ordersUrl: String };

  declare panelTarget: HTMLElement;
  declare backdropTarget: HTMLElement;
  declare frameTarget: HTMLElement & { src: string };
  declare ordersUrlValue: string;

  open() {
    this.panelTarget.classList.remove('translate-x-full');
    this.backdropTarget.classList.remove('opacity-0', 'pointer-events-none');
    document.body.classList.add('overflow-hidden');
    this.frameTarget.src = this.ordersUrlValue;
  }

  close() {
    this.panelTarget.classList.add('translate-x-full');
    this.backdropTarget.classList.add('opacity-0', 'pointer-events-none');
    document.body.classList.remove('overflow-hidden');
  }

  toggle() {
    this.panelTarget.classList.contains('translate-x-full')
      ? this.open()
      : this.close();
  }
}
