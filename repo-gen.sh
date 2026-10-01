#!/bin/bash
set -eu
set -o pipefail

gh_user="${GH_USER:-}" # use GH_USER env var to set the user
output_dir="${OUT_DIR:-out}" # where the static website will be
work_dir="${WORK_DIR:-work}" # temp directories. can get big (>2GB), so probably don't store in a ramdisk (like /tmp sometimes)
max_jobs="${MAX_JOBS:-10}" # how many parallel instances of pandoc can run at a time
pandoc_timeout="${PANDOC_TIMEOUT:-3600s}" # pandoc can take a while :/ so limit it to 10 minutes, after that it's a lost cause
# (pandoc timeouts will not stop the script. they will simply return "pandoc timed out :(" as if it were the generated html)

# you can use the REPOS env var to manually set repos
if [ "$REPOS" = "" ]; then
	repos=$(curl -s "https://api.github.com/users/$gh_user/repos?per_page=1000" | jq -r ".[] | select(.fork == false) | .name")
else
	repos="$REPOS"
fi

# you can use the EXCLUDE_REPOS env var to manually exclude repos
exclude_repos="${EXCLUDE_REPOS:-}"

# get only the repos in $repos and not in $exclude_repos
# aren't i clever?
repos=$(echo $repos $exclude_repos $exclude_repos | sed 's/ /\n/g' | sort | uniq --unique)


# pandoc command wrapper that does timeout and format stuff
pandoc() {
	timeout $pandoc_timeout pandoc -f markdown+lists_without_preceding_blankline "$@" || (echo "pandoc timed out :(" ; echo "                                pandoc timeout (args: $@)" 1>&2)
}


# ok lets go!

mkdir -vp "$output_dir"
mkdir -vp "$work_dir"

for repo in $repos; do
	echo
	echo
	echo starting $repo
	echo

	if [ -d "$work_dir/$repo" ]; then
		pushd "$work_dir/$repo"
		git pull
		popd
	else
		git clone --depth=1 "https://github.com/$gh_user/$repo" "$work_dir/$repo"
	fi

	if [ -d "$work_dir/$repo.md" ]; then echo "$work_dir/$repo.md already exists. delete? (ctrl+c to cancel)"; read ans; fi
	rm -rvf "$work_dir/$repo.md"


	# if it's just a static website (eg. already has index.html) just copy it over
	if [ -f "$work_dir/$repo/index.html" ]; then

		# copy all files, except for .git
		mkdir -vp "$output_dir/$repo/"
		find "$work_dir/$repo" -mindepth 1 -maxdepth 1 \! -name ".git" | xargs -t -I "{}" cp -av "{}" "$output_dir/$repo/"
	else # if it's *not* just a website, we need to generate stuff

		# make a dummy README.md if it doesn't exist
		if [ ! -f "$work_dir/$repo/README.md" ]; then
			echo -e "# hello world\n\nthis repo does't have a readme. pls look at repo index :)" > "$work_dir/$repo/README.md"
		fi

		# define directory for new markdown files
		# (yes the *directory* ends in .md, its not a file)
		md_dir="$work_dir/$repo.md"
		mkdir -vp "$md_dir"

		# this is a big string that gets appended to in the following loop
		repo_index_text=$'# repo index (generated)\n\n'

		# generate markdown files:

		# loop through all the files
		# do weird while loop so file paths with spaces work too
		while IFS= read file_path; do
			relative="$(echo "$file_path" | sed "s#^$work_dir\/$repo\/##")"
			base=$(basename "$relative")
			out_path="$md_dir/$relative.md" # this is the new markdown file to be made

			echo file: $file_path ======================

			mkdir -vp "$(dirname "$out_path")"

			file_info=$(file "$file_path" | cut -d: -f2-)
			file_mime=$(file --mime-type "$file_path" | cut -d: -f2-)
			file_size=$(stat "$file_path" -c "%s" | numfmt --to=si)
			file_lines=$(cat "$file_path" | wc -l)

			# generate the markdown file
			(
				echo "# $relative"
				echo
				echo "$file_size bytes. $file_lines lines"
				echo
				echo "$file_info"
				echo
				echo "$file_mime"
				echo
				echo "[view raw file]($base)"
				echo
				echo "---"
				echo
				echo -e '```'"$(echo "$relative" | sed -E 's/.*\.(\w+)/\1/')\n" # start code fence

				# text files are put directly into the markdown, binary files have (part of) their hex dump
				if echo "$file_info" | grep -q text; then
					cat "$file_path"
				else
					echo "(only showing first 131,072 bytes (128kib))"
					echo
					xxd -l 131072 "$file_path"
				fi

				echo
				echo -e '\n```\n' # end code fence
			) > "$out_path"

			# append to the repo index text
			repo_index_text=$repo_index_text"- [\`$relative\`]($relative.html)"$'\n'

		# here is the weird find command
		# it filters out directories named ".git", "monaco", etc.
		# it filters out files matching "*.uid"
		# it prints the rest
		done <<<$(find "$work_dir/$repo/" \
			-type d \( -name .git -o -name monaco -o -name monaco-editor \) -prune \
			-o \
			-type f \( -name "*.uid" \) -prune \
			-o \
			-type f -print)


		# convert the markdown into html with pandoc:

		echo
		echo rendering markdown...
		while IFS= read md_path; do
			relative="$(echo "$md_path" | sed "s#^$md_dir/##" | sed "s/\.md$//")"
			raw_path="$work_dir/$repo/$relative"
			out_path="$output_dir/$repo/$relative"
			echo -e "md: $md_path \t rel: $relative"

			# make sure the parent director(y|ies) exist
			mkdir -vp "$(dirname "$out_path")"

			# generate the html
			# only allow $max_jobs concurrent jobs (wait when there's more than $max_jobs)
			while [ $(jobs -p | wc -w) -ge "$max_jobs" ]; do wait -n; done
			cat "$md_path" | pandoc -s > "$out_path.html" &

			# copy the raw file to the output directory
			cp -v "$raw_path" "$out_path"
		done <<<$(find "$md_dir" -type f)


		# now generate the index.html from README.md
		(
			cat "$work_dir/$repo/README.md"
			echo
			echo
			echo
			echo "$repo_index_text"
			echo
		) | tee "$md_dir/index.md" | pandoc -o "$output_dir/$repo/index.html" -s

	fi
done

# TW: child neglect
echo
echo waiting for children to die...
# while there are still jobs left...
time while [ $(jobs -p | wc -w) -ge "1" ]; do
	# wait for one to exit (also reaps zombie jobs i believe?)
	# will return an error code, so just ignore that (with `|| true`)
	wait -n || true
	# print the date so, in case it takes a long time, we can know how long it's been
	echo "rip ($(jobs -p | wc -w) still alive) (its $(date "+%F %H:%M:%S"))"
done
echo ok bye
