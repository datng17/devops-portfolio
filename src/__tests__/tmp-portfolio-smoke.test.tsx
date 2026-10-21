import { render, screen } from '@testing-library/react';
import { siteContent } from '../content/site-content';
import { PortfolioPage } from '../ui/PortfolioPage';

test('smoke: PortfolioPage renders with siteContent', () => {
  const { container } = render(<PortfolioPage content={siteContent} now={new Date(2030, 0, 1)} />);
  const focusables = container.querySelectorAll('a[href], button');
  expect(focusables[0]).toHaveTextContent('Skip to main content');
  expect(container.querySelector('main#content')).toHaveAttribute('tabindex', '-1');
  expect(screen.getAllByRole('heading', { level: 1 })).toHaveLength(1);
  const ids = Array.from(container.querySelectorAll('main > section')).map((s) => s.id);
  // eslint-disable-next-line no-console
  console.log('sections:', ids.join(','), '| nav:', Array.from(container.querySelectorAll('nav a')).map((a) => a.textContent).join(','));
  expect(ids[0]).toBe('intro');
  expect(ids).not.toContain('about'); // bio is a Placeholder
  expect(container.textContent).toContain('2030');
});
