"""strip Claude Code signatures from commit messages

Mercurial counterpart of ~/.git-hooks/commit-msg and post-commit.

Removes these lines from every commit message:

  Co-Authored-By: ... <noreply@anthropic.com>
  🤖 Generated with [Claude Code](...)

Hooks cannot rewrite a message in Mercurial (pretxncommit can only reject),
so the extension wraps localrepo.commitctx: every changeset is written
through it — commit, commit --amend, a message typed in the editor, rebase,
graft, histedit — and the message is cleaned right before it is stored.
"""

import re

testedwith = b'7.1'

SIGNATURE_LINE = re.compile(
    rb'^(?:[Cc]o-[Aa]uthored-[Bb]y:.*<noreply@anthropic\.com>'
    rb'|.*\xf0\x9f\xa4\x96 Generated with \[Claude Code\].*)[ \t]*$'
)


def strip_signature(text):
    lines = text.split(b'\n')
    kept = [line for line in lines if not SIGNATURE_LINE.match(line)]

    if len(kept) == len(lines):
        return text

    return b'\n'.join(kept).rstrip(b'\n')


def reposetup(ui, repo):
    if not repo.local():
        return

    class signaturestrippingrepo(repo.__class__):
        def commitctx(self, ctx, *args, **kwargs):
            text = getattr(ctx, '_text', None)

            if text:
                ctx._text = strip_signature(text)

            return super().commitctx(ctx, *args, **kwargs)

    repo.__class__ = signaturestrippingrepo
