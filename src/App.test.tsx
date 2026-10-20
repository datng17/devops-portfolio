import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import App from './App';

describe('App', () => {
  test('renders without crashing', () => {
    render(<App />);
    expect(screen.getByTestId('app-root')).toBeInTheDocument();
  });

  test('renders the name heading and key sections', () => {
    render(<App />);
    expect(screen.getByRole('heading', { level: 1, name: 'Dat Nguyen' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Expertise' })).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: 'Contact Me' })).toBeInTheDocument();
  });

  test('mode toggle switches between dark-mode and light-mode in both directions', () => {
    render(<App />);
    const root = screen.getByTestId('app-root');

    // Initial state: dark mode, nav shows the "switch to light" icon.
    expect(root).toHaveClass('dark-mode');
    expect(root).not.toHaveClass('light-mode');
    expect(screen.queryByTestId('DarkModeIcon')).not.toBeInTheDocument();

    // Dark -> light
    fireEvent.click(screen.getByTestId('LightModeIcon'));
    expect(root).toHaveClass('light-mode');
    expect(root).not.toHaveClass('dark-mode');
    expect(screen.queryByTestId('LightModeIcon')).not.toBeInTheDocument();

    // Light -> dark
    fireEvent.click(screen.getByTestId('DarkModeIcon'));
    expect(root).toHaveClass('dark-mode');
    expect(root).not.toHaveClass('light-mode');
    expect(screen.getByTestId('LightModeIcon')).toBeInTheDocument();
  });

  test('renders the navigation items', () => {
    render(<App />);
    for (const label of ['Expertise', 'History', 'Projects', 'Contact']) {
      expect(screen.getAllByRole('button', { name: label }).length).toBeGreaterThan(0);
    }
  });
});
