package main

import (
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// goose applies migrations against a live database, so the order is asserted
// where it is decided: the step list a command produces. What runs each step
// is a single goose call per step.
func TestMigrationStepsOrder(t *testing.T) {
	const subdir = "migrations/inventory"
	extra := t.TempDir()

	for _, tt := range []struct {
		name     string
		command  string
		extraDir string
		want     []migrationStep
	}{
		{
			name:    "up without an extra directory",
			command: "up",
			want:    []migrationStep{{dir: subdir, embedded: true}},
		},
		{
			name:     "up applies the embedded set first",
			command:  "up",
			extraDir: extra,
			want:     []migrationStep{{dir: subdir, embedded: true}, {dir: extra}},
		},
		{
			name:     "down acts on the extra directory",
			command:  "down",
			extraDir: extra,
			want:     []migrationStep{{dir: extra}},
		},
		{
			name:    "down without an extra directory acts on the embedded set",
			command: "down",
			want:    []migrationStep{{dir: subdir, embedded: true}},
		},
		{
			name:     "status acts on the extra directory",
			command:  "status",
			extraDir: extra,
			want:     []migrationStep{{dir: extra}},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, err := migrationSteps(tt.command, subdir, tt.extraDir)
			if err != nil {
				t.Fatalf("migrationSteps: %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("steps = %v, want %v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("step %d = %v, want %v", i, got[i], tt.want[i])
				}
			}
		})
	}
}

func TestMigrationStepsRejectsAnUnknownCommand(t *testing.T) {
	if _, err := migrationSteps("sideways", "migrations/inventory", ""); err == nil {
		t.Error("migrationSteps accepted an unknown command")
	}
}

// The extra directory is read from the host filesystem, which is what the
// scenario 2 Job mounts its ConfigMap into.
func TestExtraDirectoryIsReadFromTheHost(t *testing.T) {
	extra := t.TempDir()
	if err := os.WriteFile(filepath.Join(extra, "003_rename_quantity.sql"), []byte("-- +goose Up\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	steps, err := migrationSteps("up", "migrations/inventory", extra)
	if err != nil {
		t.Fatalf("migrationSteps: %v", err)
	}
	last := steps[len(steps)-1]
	if last.embedded {
		t.Fatal("the extra directory is marked embedded")
	}
	if _, err := os.Stat(filepath.Join(last.dir, "003_rename_quantity.sql")); err != nil {
		t.Errorf("the step does not name a readable directory: %v", err)
	}
}

func TestEmbeddedSource(t *testing.T) {
	for _, tt := range []struct {
		dir    string
		subdir string
		files  []string
	}{
		{"inventory", "migrations/inventory", []string{"001_schema.sql", "002_seed.sql"}},
		{"orders", "migrations/orders", []string{"001_schema.sql"}},
	} {
		t.Run(tt.dir, func(t *testing.T) {
			migrations, subdir, err := embeddedSource(tt.dir)
			if err != nil {
				t.Fatalf("embeddedSource(%q): %v", tt.dir, err)
			}
			if subdir != tt.subdir {
				t.Errorf("subdir = %q, want %q", subdir, tt.subdir)
			}
			entries, err := fs.ReadDir(migrations, subdir)
			if err != nil {
				t.Fatalf("read %s: %v", subdir, err)
			}
			var got []string
			for _, e := range entries {
				got = append(got, e.Name())
			}
			if len(got) != len(tt.files) {
				t.Fatalf("files = %v, want %v", got, tt.files)
			}
			for i := range got {
				if got[i] != tt.files[i] {
					t.Errorf("file %d = %q, want %q", i, got[i], tt.files[i])
				}
			}
		})
	}
}

func TestEmbeddedSourceRejectsAnUnknownSet(t *testing.T) {
	if _, _, err := embeddedSource("shipping"); err == nil {
		t.Error("embeddedSource accepted an unknown migration set")
	}
}
