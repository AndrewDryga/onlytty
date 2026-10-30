# Tools are installed at the versions in .tool-versions.
# After changing that file, run coop build to rebuild this project's box.
# Coop's box image brings the agent CLIs and editor adapters, at the versions Coop qualifies.
ARG COOP_BASE_IMAGE=coop-box
FROM ${COOP_BASE_IMAGE}

# Packages this project's tools need beyond Coop's box.
# Add build dependencies here when you add tools to .tool-versions.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      autoconf build-essential gnupg libncurses-dev libssl-dev m4 \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
USER node

# Coop's filtered client image keeps asdf's shims off PATH, so put them back — after the client
# launchers, which nothing may shadow.
ENV PATH="/opt/coop/bin:/home/node/.asdf/shims:${PATH}" \
    KERL_BUILD_DOCS=no \
    KERL_CONFIGURE_OPTIONS="--without-wx --without-observer --without-debugger --without-et --without-megaco --without-javac"

# Install the tool versions declared by the project.
# Installation failures stop the build.
COPY --chown=node:node .tool-versions /home/node/.tool-versions
RUN cd /home/node \
 && awk 'NF && $1 !~ /^#/ {print $1}' .tool-versions | while read -r tool; do asdf plugin add "$tool" || exit 1; done \
 && MAKEFLAGS="-j$(nproc)" asdf install \
 && asdf reshim \
 && { command -v mix >/dev/null 2>&1 && mix local.hex --force && mix local.rebar --force || true; }

# Login shells reset PATH, so restore the same order after /etc/profile runs (this drop-in sorts
# after Coop's own, which leaves the shims out in a filtered box).
USER root
RUN printf 'export PATH="/opt/coop/bin:/home/node/.asdf/shims:$PATH"\n' > /etc/profile.d/zz-asdf.sh
USER node

WORKDIR /workspace
