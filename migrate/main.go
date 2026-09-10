// migrate runs goose database migrations for the example stack.
// It embeds SQL migration files and runs them against a target database.
//
// Usage: migrate -database <dsn> -dir <inventory|orders> [-extra-dir <path>]
package main

import (
	"database/sql"
	"embed"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	_ "github.com/lib/pq"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/inventory/*.sql
var inventoryMigrations embed.FS

//go:embed migrations/orders/*.sql
var ordersMigrations embed.FS

func main() {
	dsn := flag.String("database", "", "PostgreSQL connection string")
	dir := flag.String("dir", "", "Migration directory: inventory or orders")
	extraDir := flag.String("extra-dir", "", "Filesystem directory of additional migrations, applied after the embedded set")
	flag.Parse()

	if *dsn == "" {
		*dsn = os.Getenv("DATABASE_URL")
	}
	if *dsn == "" {
		log.Fatal("database connection string required: -database <dsn> or DATABASE_URL env")
	}
	if *dir == "" {
		*dir = os.Getenv("MIGRATION_DIR")
	}
	if *dir == "" {
		log.Fatal("migration directory required: -dir <inventory|orders> or MIGRATION_DIR env")
	}
	if *extraDir == "" {
		*extraDir = os.Getenv("MIGRATION_EXTRA_DIR")
	}

	migrations, subdir, err := embeddedSource(*dir)
	if err != nil {
		log.Fatal(err)
	}

	command := "up"
	if args := flag.Args(); len(args) > 0 {
		command = args[0]
	}

	// Both bad arguments are rejected before the database is opened, so a
	// mistyped Job fails at once instead of after the ping retries.
	steps, err := migrationSteps(command, subdir, *extraDir)
	if err != nil {
		log.Fatal(err)
	}

	db, err := sql.Open("postgres", *dsn)
	if err != nil {
		log.Fatalf("failed to open database: %v", err)
	}
	defer db.Close()

	// Retry the initial ping for up to ~60s. On a fresh cluster postgres may
	// still be running initdb when this Job starts; transient blips elsewhere
	// have the same shape.
	const pingTimeout = 60 * time.Second
	deadline := time.Now().Add(pingTimeout)
	for attempt := 1; ; attempt++ {
		err := db.Ping()
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			log.Fatalf("failed to ping database after %s (last error: %v)", pingTimeout, err)
		}
		log.Printf("attempt %d: database not reachable: %v", attempt, err)
		time.Sleep(2 * time.Second)
	}

	if err := goose.SetDialect("postgres"); err != nil {
		log.Fatalf("failed to set dialect: %v", err)
	}

	fmt.Printf("==> Running %s migrations (%s)\n", *dir, command)

	for _, step := range steps {
		if step.embedded {
			goose.SetBaseFS(migrations)
		} else {
			// A nil base filesystem sends goose back to the host filesystem.
			goose.SetBaseFS(nil)
			fmt.Printf("==> Running additional %s migrations from %s\n", *dir, step.dir)
		}
		if err := runGoose(db, command, step.dir); err != nil {
			log.Fatalf("migration failed: %v", err)
		}
	}
	fmt.Printf("==> %s migrations complete\n", *dir)
}

// embeddedSource names the embedded filesystem and the directory inside it
// that holds a migration set.
func embeddedSource(dir string) (embed.FS, string, error) {
	switch dir {
	case "inventory":
		return inventoryMigrations, "migrations/inventory", nil
	case "orders":
		return ordersMigrations, "migrations/orders", nil
	}
	return embed.FS{}, "", fmt.Errorf("unknown migration directory: %s (expected inventory or orders)", dir)
}

// migrationStep is one directory a command reads, and which filesystem it
// reads it from.
type migrationStep struct {
	dir      string
	embedded bool
}

// migrationSteps orders the sources a command reads. The embedded set and the
// extra directory share one goose_db_version table, so version numbers in the
// extra directory must continue the embedded sequence: up applies the embedded
// set first and the extra directory after it. down and status act on the extra
// directory when one is given, because that is where the newest migrations are.
func migrationSteps(command, subdir, extraDir string) ([]migrationStep, error) {
	switch command {
	case "up":
		steps := []migrationStep{{dir: subdir, embedded: true}}
		if extraDir != "" {
			steps = append(steps, migrationStep{dir: extraDir})
		}
		return steps, nil
	case "down", "status":
		if extraDir != "" {
			return []migrationStep{{dir: extraDir}}, nil
		}
		return []migrationStep{{dir: subdir, embedded: true}}, nil
	}
	return nil, fmt.Errorf("unknown command: %s (expected up, down, or status)", command)
}

func runGoose(db *sql.DB, command, dir string) error {
	switch command {
	case "up":
		return goose.Up(db, dir)
	case "down":
		return goose.Down(db, dir)
	case "status":
		return goose.Status(db, dir)
	}
	return fmt.Errorf("unknown command: %s (expected up, down, or status)", command)
}
