#!/bin/bash
set -eu
set -o pipefail

site_git_dir="./site"
out_dir="./out"
repos_dir="./repos"
repos_work_dir="./repos.work"
max_jobs=10
repos="$(cat << EOF
raytracing-web
notd
psychedelics
pi
new-raytracing
web-shaderer
image-maker
canvas-playground
css-tester
spirograph
eulers-spiral
dabeef
EOF
)"

mkdir -vp "$out_dir"

if [ -d "$site_git_dir" ]; then
	pushd "$site_git_dir"
	git pull
	popd
else
	git clone --depth=1 "https://github.com/calsch/calsch.github.io" "$site_git_dir"
fi

hugo build -s "$site_git_dir"

cp -av "$site_git_dir"/public/* "$out_dir"


GH_USER=calsch \
OUT_DIR="$repos_dir" \
WORK_DIR="$repos_work_dir" \
MAX_JOBS="$max_jobs" \
REPOS="$repos" \
bash repo-gen.sh

cp -av "$repos_dir"/* "$out_dir/"
