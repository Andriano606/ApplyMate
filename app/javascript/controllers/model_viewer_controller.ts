import { Controller } from '@hotwired/stimulus';
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

export default class ModelViewerController extends Controller {
  static values = {
    url: String,
  };

  declare urlValue: string;

  private renderer: THREE.WebGLRenderer | null = null;
  private scene!: THREE.Scene;
  private camera!: THREE.PerspectiveCamera;
  private controls!: OrbitControls;
  private animationId = 0;
  private canvas!: HTMLCanvasElement;
  private spinner!: HTMLElement;
  private resizeObserver!: ResizeObserver;

  connect() {
    this.buildDOM();
    this.initThree();
    this.loadModel();
    this.animate();
    this.observeResize();
  }

  disconnect() {
    this.resizeObserver?.disconnect();
    if (this.renderer) {
      this.renderer.dispose();
      this.renderer.forceContextLoss();

      if (this.renderer.domElement?.parentNode) {
        this.renderer.domElement.parentNode.removeChild(
          this.renderer.domElement,
        );
      }

      // Зануляємо весь об'єкт.
      // Це безпечно і TypeScript дозволить це, якщо тип WebGLRenderer | null
      this.renderer = null;
    }
  }

  // ── DOM ──────────────────────────────────────────────────────────────────

  private buildDOM() {
    this.spinner = document.createElement('div');
    this.spinner.className =
      'absolute inset-0 flex items-center justify-center text-gray-400 dark:text-gray-500';
    this.spinner.innerHTML = `
      <svg class="animate-spin h-6 w-6" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"/>
        <path class="opacity-75" fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962
             7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"/>
      </svg>`;
    this.element.appendChild(this.spinner);

    this.canvas = document.createElement('canvas');
    this.canvas.className =
      'absolute inset-0 opacity-0 transition-opacity duration-300';
    this.element.appendChild(this.canvas);
  }

  // ── Three.js setup ───────────────────────────────────────────────────────

  private initThree() {
    const el = this.element as HTMLElement;
    const w = el.offsetWidth || 400;
    const h = el.offsetHeight || 400;

    this.renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      antialias: true,
      alpha: true,
    });
    // false = не встановлювати CSS-стилі на canvas, щоб Tailwind w-full/h-full працювало
    this.renderer.setSize(w, h, false);
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    this.renderer.toneMapping = THREE.ACESFilmicToneMapping;
    this.renderer.toneMappingExposure = 1.6;

    this.scene = new THREE.Scene();

    this.camera = new THREE.PerspectiveCamera(45, w / h, 0.01, 100000);
    this.camera.position.set(0, 0, 100);

    const ambient = new THREE.AmbientLight(0xffffff, 0.6);
    const dir1 = new THREE.DirectionalLight(0xffffff, 2.8);
    dir1.position.set(1, 2, 3);
    const dir2 = new THREE.DirectionalLight(0xffffff, 0.4);
    dir2.position.set(-1, -1, -1);
    const dirBack = new THREE.DirectionalLight(0xffffff, 1.4);
    dirBack.position.set(0, 1, -3);
    this.scene.add(ambient, dir1, dir2, dirBack);

    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.08;
  }

  private animate() {
    this.animationId = requestAnimationFrame(() => this.animate());
    this.controls?.update();
    this.renderer?.render(this.scene, this.camera);
  }

  // ── Loader ───────────────────────────────────────────────────────────────

  private loadModel() {
    new GLTFLoader().load(
      this.urlValue,
      (gltf) => this.addObject(gltf.scene),
      undefined,
      () => this.showError(),
    );
  }

  private addObject(object: THREE.Object3D) {
    this.scene.add(object);
    this.fitCamera(object);
    this.spinner.remove();
    this.canvas.classList.remove('opacity-0');
  }

  private fitCamera(object: THREE.Object3D) {
    object.updateMatrixWorld(true);
    const box = new THREE.Box3().setFromObject(object);
    const center = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());

    // Center model at origin
    object.position.sub(center);

    const bottomY = -size.y / 2;
    this.addFloorAndGrid(size, bottomY);

    const vFov = this.camera.fov * (Math.PI / 180);
    const hFov = 2 * Math.atan(Math.tan(vFov / 2) * this.camera.aspect);
    const fov = Math.min(vFov, hFov);

    // Bounding sphere radius — most accurate fit for any orientation
    const radius = size.length() / 2;
    const dist = radius / Math.tan(fov / 2);

    // Normalize camera direction so actual distance from origin == dist
    const camDir = new THREE.Vector3(0.7, 0.5, 1).normalize();
    this.camera.position.copy(camDir.multiplyScalar(dist));
    this.camera.near = dist / 200;
    this.camera.far = dist * 200;
    this.camera.lookAt(0, 0, 0);
    this.camera.updateProjectionMatrix();

    this.controls.target.set(0, 0, 0);
    this.controls.update();
  }

  private addFloorAndGrid(size: THREE.Vector3, bottomY: number) {
    const STEP = 25; // 25 mm grid step
    const footprint = Math.max(size.x, size.z);
    // Span = 2× footprint, rounded up to nearest 25 mm multiple
    const span = Math.ceil((footprint * 2) / STEP) * STEP;
    const divisions = Math.round(span / STEP);

    const grid = new THREE.GridHelper(span, divisions, 0x999999, 0xdddddd);
    grid.position.y = bottomY;
    this.scene.add(grid);

    const floorGeo = new THREE.PlaneGeometry(span, span);
    const floorMat = new THREE.MeshStandardMaterial({
      color: 0xf5f5f5,
      transparent: true,
      opacity: 0.35,
      roughness: 1,
      metalness: 0,
    });
    const floor = new THREE.Mesh(floorGeo, floorMat);
    floor.rotation.x = -Math.PI / 2;
    floor.position.y = bottomY - 0.001;
    this.scene.add(floor);
  }

  private observeResize() {
    this.resizeObserver = new ResizeObserver(() => {
      if (!this.renderer) return;
      const w = (this.element as HTMLElement).offsetWidth;
      const h = (this.element as HTMLElement).offsetHeight;
      if (w === 0 || h === 0) return;
      this.renderer.setSize(w, h, false);
      this.camera.aspect = w / h;
      this.camera.updateProjectionMatrix();
    });
    this.resizeObserver.observe(this.element);
  }

  private showError(msg = 'Failed to load model') {
    this.spinner.innerHTML = `<span class="text-xs text-red-400">${msg}</span>`;
  }
}
