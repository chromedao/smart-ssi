# Smart-SSI issuer API: verifies TLSNotary presentations and writes attestations to the Solana Attestation Service.
# Build from the repository root:  docker build -f deploy/issuer.Dockerfile -t smart-ssi-issuer .
# Keys are never in the image: on Cloud Run they come from Secret Manager (ISSUER_KEYS).
FROM rust:1-bookworm AS verifier
WORKDIR /src
RUN git clone --depth 1 --branch v0.1.0-alpha.15 https://github.com/tlsnotary/tlsn.git vendor/tlsn
COPY prover prover
RUN cd prover && cargo build --release --locked --bin smart-ssi-prover

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=verifier /src/prover/target/release/smart-ssi-prover /usr/local/bin/smart-ssi-prover
WORKDIR /app/issuer
COPY issuer/package.json issuer/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY issuer/src ./src
ENV PROVER_BIN=/usr/local/bin/smart-ssi-prover DATA_DIR=/tmp/smart-ssi NODE_ENV=production
CMD ["npx", "tsx", "src/server.ts"]
