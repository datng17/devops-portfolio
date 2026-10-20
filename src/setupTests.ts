// jest-dom adds custom jest matchers for asserting on DOM nodes.
// allows you to do things like:
// expect(element).toHaveTextContent(/react/i)
// learn more: https://github.com/testing-library/jest-dom
import '@testing-library/jest-dom';

// jsdom does not implement window.scrollTo (App.tsx calls it on mount).
Object.defineProperty(window, 'scrollTo', { value: jest.fn(), writable: true });

// jsdom does not implement Element.scrollIntoView (Navigation.tsx calls it on nav click).
Object.defineProperty(window.HTMLElement.prototype, 'scrollIntoView', {
  value: jest.fn(),
  writable: true,
});

// jsdom does not implement IntersectionObserver. react-vertical-timeline-component
// uses react-intersection-observer's <InView>, which constructs one on mount.
class MockIntersectionObserver implements IntersectionObserver {
  readonly root: Element | Document | null = null;
  readonly rootMargin: string = '';
  readonly thresholds: ReadonlyArray<number> = [];
  observe = jest.fn();
  unobserve = jest.fn();
  disconnect = jest.fn();
  takeRecords = jest.fn((): IntersectionObserverEntry[] => []);
}
Object.defineProperty(window, 'IntersectionObserver', {
  value: MockIntersectionObserver,
  writable: true,
});
