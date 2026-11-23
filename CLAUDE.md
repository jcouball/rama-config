<!-- jcouball-github guardrails: begin sha256:f3d2a6edbe01 -->
Never commit or push to `main` or `master`. Create a topic branch
first (`git switch -c <type>/<short-description>`) and open a pull
request instead.
<!-- jcouball-github guardrails: end -->

A pull request does not need a certification run to merge. It needs review and
evidence that the change itself works: a script run against stand-ins, a test
of the logic. Say in the pull request what was done.

Certification comes after the merge. `main` is certified when there is
something on it that a rebuild should get, and one run can cover several
merged changes. "Certify the rebuild" in the README says what needs a run
before it reaches `stable`, the branch a rebuild clones, and what does not.

A branch run before the merge (`./certification/certify.sh --branch <branch>`,
from a scratch clone on rama) is still worth making for a new script under
`.chezmoiscripts`. Make it once, after review, on the commit that will merge.

Certifying and recording happen on rama (`ssh rama`), in the chezmoi source,
which follows `main`. `certify.sh` can be run over ssh. `record.sh` and
`chezmoi update` need the sudo password, so ask the owner to run those; never
report a run that did not happen. Nothing but `record.sh` pushes to `stable`.
