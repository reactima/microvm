// count_lines_changed.go
// Summarize lines added and removed per developer within a date range.
package main

import (
	"flag"
	"fmt"
	"log"
	"sort"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing/object"
)

type stats struct {
	added   int
	removed int
}

func main() {
	repoPath := flag.String("repo", ".", "path to git repo")
	sinceStr := flag.String("since", "", "start date (YYYY-MM-DD)")
	untilStr := flag.String("until", "", "end date (YYYY-MM-DD)")
	flag.Parse()

	if *sinceStr == "" || *untilStr == "" {
		log.Fatal("Must specify -since and -until")
	}

	since, err := time.Parse("2006-01-02", *sinceStr)
	if err != nil {
		log.Fatalf("invalid since date: %v", err)
	}
	until, err := time.Parse("2006-01-02", *untilStr)
	if err != nil {
		log.Fatalf("invalid until date: %v", err)
	}

	r, err := git.PlainOpen(*repoPath)
	if err != nil {
		log.Fatalf("opening repo: %v", err)
	}

	head, err := r.Head()
	if err != nil {
		log.Fatalf("getting HEAD: %v", err)
	}
	cIter, err := r.Log(&git.LogOptions{From: head.Hash()})
	if err != nil {
		log.Fatalf("getting commit log: %v", err)
	}

	authors := make(map[string]*stats)
	err = cIter.ForEach(func(c *object.Commit) error {
		if c.Author.When.Before(since) || c.Author.When.After(until) {
			return nil
		}

		var patch *object.Patch
		if c.NumParents() > 0 {
			parent, err := c.Parents().Next()
			if err != nil {
				return err
			}
			patch, err = parent.Patch(c)
			if err != nil {
				return err
			}
		} else {
			patch, err = c.Patch(nil)
			if err != nil {
				return err
			}
		}

		key := fmt.Sprintf("%s <%s>", c.Author.Name, c.Author.Email)
		if _, ok := authors[key]; !ok {
			authors[key] = &stats{}
		}
		for _, stat := range patch.Stats() {
			authors[key].added += stat.Addition
			authors[key].removed += stat.Deletion
		}
		return nil
	})
	if err != nil {
		log.Fatalf("iterating commits: %v", err)
	}

	type row struct {
		author                string
		added, removed, total int
	}
	var rows []row
	var grandAdded, grandRemoved int
	for a, s := range authors {
		rows = append(rows, row{author: a, added: s.added, removed: s.removed, total: s.added + s.removed})
		grandAdded += s.added
		grandRemoved += s.removed
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].total > rows[j].total })

	fmt.Printf("From %s to %s\n\n", since.Format("2006-01-02"), until.Format("2006-01-02"))
	for _, r := range rows {
		fmt.Printf("%-30s added: %6d removed: %6d total: %6d\n", r.author, r.added, r.removed, r.total)
	}
	fmt.Printf("\nGRAND TOTAL  added: %d  removed: %d  total: %d\n", grandAdded, grandRemoved, grandAdded+grandRemoved)
}
