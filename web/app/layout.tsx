import type { Metadata } from 'next';
import './globals.css';
export const metadata: Metadata = {
  title: 'vFrame / frame playground',
  icons: { icon: '/favicon.svg' },
  description:
    'Compose, reorder and execute frame transactions on Ethereum Sepolia.',
};
export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>
        <div id="app">{children}</div>
      </body>
    </html>
  );
}
