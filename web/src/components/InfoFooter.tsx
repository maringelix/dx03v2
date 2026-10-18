import type { ApiInfo } from '../api.ts';

interface Props {
  info: ApiInfo | undefined;
  failed: boolean;
}

export function InfoFooter({ info, failed }: Props) {
  let content = 'Loading API information…';
  if (failed) {
    content = 'API information is unavailable.';
  } else if (info !== undefined) {
    const commit = /^[0-9a-f]{7,40}$/.test(info.commit) ? info.commit.slice(0, 7) : info.commit;
    content = `API ${info.version} · commit ${commit} · environment ${info.environment}`;
  }
  return (
    <footer className="footer">
      <p>{content}</p>
      <p className="muted">dx03v2 · educational lab · open source (MIT)</p>
    </footer>
  );
}
