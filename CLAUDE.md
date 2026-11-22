<!-- jcouball-github guardrails: begin sha256:f3d2a6edbe01 -->
Never commit or push to `main` or `master`. Create a topic branch
first (`git switch -c <type>/<short-description>`) and open a pull
request instead.
<!-- jcouball-github guardrails: end -->

A change to a script under `.chezmoiscripts`, to a package list, to
`.chezmoi.toml.tmpl`, to `certification/verify.sh`, or to anything else a
rebuild runs or reads needs a certification run from its branch before it
merges. Run `./certification/certify.sh --branch <branch>` on rama
(`ssh rama`), where the container is amd64, and put the commit and the verdict
in the pull request. See "Certify the rebuild" in the README.
