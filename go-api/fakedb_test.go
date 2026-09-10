package main

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

// A fake database/sql driver, so the handlers run the SQL they actually ship
// against a substitute. sql.OpenDB takes a connector directly, which keeps the
// fake out of the global driver registry and lets each test have its own.
type fakeDB struct {
	orders []Order // rows the list and get queries answer with
	// failOn makes any query containing this substring return an error, which
	// is how the read and write failure paths are reached.
	failOn string
	// listErr is returned after the last listed row, the shape of a read that
	// fails partway through.
	listErr error
	pingErr error
	// inserted records the arguments of each INSERT, so a test can assert what
	// the create handler stored.
	inserted [][]driver.Value
}

var errFakeQuery = errors.New("fake database: query failed")

func openFakeDB(f *fakeDB) *sql.DB {
	return sql.OpenDB(&fakeConnector{db: f})
}

type fakeConnector struct{ db *fakeDB }

func (c *fakeConnector) Connect(context.Context) (driver.Conn, error) {
	return &fakeConn{db: c.db}, nil
}

func (c *fakeConnector) Driver() driver.Driver { return fakeDriver{} }

type fakeDriver struct{}

func (fakeDriver) Open(string) (driver.Conn, error) {
	return nil, errors.New("fake database: opened by name, use the connector")
}

type fakeConn struct{ db *fakeDB }

func (c *fakeConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("fake database: prepared statements are not supported")
}

func (c *fakeConn) Close() error { return nil }
func (c *fakeConn) Begin() (driver.Tx, error) {
	return nil, errors.New("fake database: no transactions")
}

func (c *fakeConn) Ping(context.Context) error { return c.db.pingErr }

func (c *fakeConn) QueryContext(_ context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	if c.db.failOn != "" && strings.Contains(query, c.db.failOn) {
		return nil, errFakeQuery
	}
	switch {
	case strings.Contains(query, "COUNT(*)"):
		return &fakeRows{cols: []string{"count"}, vals: [][]driver.Value{{int64(len(c.db.orders))}}}, nil
	case strings.Contains(query, "INSERT INTO orders"):
		vals := make([]driver.Value, 0, len(args))
		for _, a := range args {
			vals = append(vals, a.Value)
		}
		c.db.inserted = append(c.db.inserted, vals)
		return &fakeRows{cols: []string{"created_at"}, vals: [][]driver.Value{{time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)}}}, nil
	case strings.Contains(query, "FROM orders WHERE id"):
		want := fmt.Sprint(args[0].Value)
		for _, o := range c.db.orders {
			if o.ID == want {
				return orderRows([]Order{o}, nil), nil
			}
		}
		return orderRows(nil, nil), nil
	case strings.Contains(query, "FROM orders"):
		return orderRows(c.db.orders, c.db.listErr), nil
	}
	return nil, fmt.Errorf("fake database: unexpected query %q", query)
}

func (c *fakeConn) ExecContext(_ context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	if c.db.failOn != "" && strings.Contains(query, c.db.failOn) {
		return nil, errFakeQuery
	}
	if strings.Contains(query, "DELETE FROM orders") {
		want := fmt.Sprint(args[0].Value)
		for i, o := range c.db.orders {
			if o.ID == want {
				c.db.orders = append(c.db.orders[:i], c.db.orders[i+1:]...)
				return fakeResult(1), nil
			}
		}
		return fakeResult(0), nil
	}
	return nil, fmt.Errorf("fake database: unexpected statement %q", query)
}

type fakeResult int64

func (r fakeResult) LastInsertId() (int64, error) { return 0, nil }
func (r fakeResult) RowsAffected() (int64, error) { return int64(r), nil }

// orderRows returns the column set the order queries select, in that order.
func orderRows(orders []Order, err error) *fakeRows {
	rows := &fakeRows{
		cols: []string{"id", "item_id", "item_name", "quantity", "unit_price", "total", "currency", "warehouse", "created_at"},
		err:  err,
	}
	for _, o := range orders {
		created, _ := time.Parse(time.RFC3339, o.CreatedAt)
		rows.vals = append(rows.vals, []driver.Value{
			o.ID, o.ItemID, o.ItemName, int64(o.Quantity),
			o.UnitPrice, o.Total, o.Currency, o.Warehouse, created,
		})
	}
	return rows
}

type fakeRows struct {
	cols []string
	vals [][]driver.Value
	idx  int
	err  error
}

func (r *fakeRows) Columns() []string { return r.cols }
func (r *fakeRows) Close() error      { return nil }

func (r *fakeRows) Next(dest []driver.Value) error {
	if r.idx >= len(r.vals) {
		if r.err != nil {
			return r.err
		}
		return io.EOF
	}
	copy(dest, r.vals[r.idx])
	r.idx++
	return nil
}
