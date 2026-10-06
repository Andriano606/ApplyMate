import { Controller } from '@hotwired/stimulus';

// Opens, scrolls to and marks (data-highlighted) the element a URL fragment points at:
// - reveal (turbo:frame-load): the browser and Turbo only scroll to an anchor that exists at render time, so
//   /vacancies/:id#apply_<hashid> would otherwise stay at the top. Runs once per element: later loads (tab
//   switches inside the frame) and broadcast replacements must not yank the page back.
// - follow (hashchange@window): back/forward between in-page anchors.
// - jump (click on an in-page link): its target sits in a collapsed <details>, and clicking the same link
//   again fires no hashchange.
// CSS :target never matches here (lazily inserted nodes, Turbo's pushState), hence the data attribute.
export default class extends Controller {
  private revealed = false;

  reveal(): void {
    if (this.revealed) return;

    const target = this.findTarget(window.location.hash);
    if (!target || !this.element.contains(target)) return;

    this.revealed = true;
    this.open(target);
  }

  follow(): void {
    const target = this.findTarget(window.location.hash);
    if (target && this.element.contains(target)) this.open(target);
  }

  jump(event: Event): void {
    const link = event.currentTarget as HTMLAnchorElement;
    // After the browser has applied the hash, so its own scroll does not undo ours.
    requestAnimationFrame(() => {
      const target = this.findTarget(link.hash);
      if (target) this.open(target);
    });
  }

  private findTarget(hash: string): HTMLElement | null {
    const id = decodeURIComponent(hash.slice(1));
    return id ? document.getElementById(id) : null;
  }

  private open(target: HTMLElement): void {
    document.querySelectorAll<HTMLElement>('[data-highlighted]').forEach((element) => {
      if (element !== target) delete element.dataset.highlighted;
    });
    target.dataset.highlighted = '';
    target.querySelector('details')?.setAttribute('open', '');
    target.scrollIntoView({ block: 'start' });
  }
}
