// Order-management UI for the example stack. Talks to nginx at the same
// origin; nginx injects the bearer token, so no auth lives in the browser.
// Kept deliberately small: no build step, no framework.

const $ = (sel) => document.querySelector(sel);
const inventoryBody = $('#inventory-table tbody');
const ordersBody = $('#orders-table tbody');
const itemSelect = document.querySelector('#order-form select[name=item_id]');
const banner = $('#error-banner');
const orderResult = $('#order-result');

let inventoryCache = [];

function showError(context, err) {
  banner.textContent = `${context}: ${err}`;
  banner.classList.remove('hidden');
}

function clearError() {
  banner.classList.add('hidden');
  banner.textContent = '';
}

async function apiCall(method, path, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const resp = await fetch(path, opts);
  const text = await resp.text();
  let parsed = null;
  try { parsed = text ? JSON.parse(text) : null; } catch (_) { /* leave as text */ }
  if (!resp.ok) {
    const detail = parsed ? JSON.stringify(parsed) : text;
    throw new Error(`${resp.status} ${resp.statusText} - ${detail}`);
  }
  return parsed;
}

function rowEmpty(colspan, text) {
  const tr = document.createElement('tr');
  tr.className = 'empty';
  const td = document.createElement('td');
  td.colSpan = colspan;
  td.textContent = text;
  tr.appendChild(td);
  return tr;
}

async function loadInventory() {
  try {
    const data = await apiCall('GET', '/api/v1/inventory');
    const items = Array.isArray(data) ? data : (data.items || data.inventory || []);
    inventoryCache = items;
    inventoryBody.innerHTML = '';
    if (items.length === 0) {
      inventoryBody.appendChild(rowEmpty(4, 'no inventory'));
    } else {
      for (const it of items) {
        const tr = document.createElement('tr');
        tr.innerHTML = `<td>${escape(it.name)}</td><td>${it.quantity}</td><td>${escape(it.warehouse)}</td><td class="mono">${escape(it.id)}</td>`;
        inventoryBody.appendChild(tr);
      }
    }
    populateItemSelect(items);
  } catch (err) {
    showError('inventory load failed', err.message);
    inventoryBody.innerHTML = '';
    inventoryBody.appendChild(rowEmpty(4, 'load failed - see banner'));
  }
}

function populateItemSelect(items) {
  const prev = itemSelect.value;
  itemSelect.innerHTML = '';
  for (const it of items) {
    const opt = document.createElement('option');
    opt.value = it.id;
    opt.textContent = `${it.name} (${it.quantity} in ${it.warehouse})`;
    itemSelect.appendChild(opt);
  }
  if (prev && items.some((i) => i.id === prev)) itemSelect.value = prev;
}

async function loadOrders() {
  try {
    const data = await apiCall('GET', '/api/v1/orders');
    const orders = data.orders || [];
    ordersBody.innerHTML = '';
    if (orders.length === 0) {
      ordersBody.appendChild(rowEmpty(7, 'no orders yet'));
      return;
    }
    for (const o of orders) {
      const tr = document.createElement('tr');
      tr.innerHTML = `
        <td class="mono">${formatTime(o.created_at)}</td>
        <td>${escape(o.item_name)}</td>
        <td>${o.quantity}</td>
        <td>${formatMoney(o.unit_price)}</td>
        <td>${formatMoney(o.total)}</td>
        <td>${escape(o.currency)}</td>
        <td></td>
      `;
      const btn = document.createElement('button');
      btn.className = 'delete';
      btn.textContent = 'delete';
      btn.addEventListener('click', () => deleteOrder(o.id));
      tr.lastElementChild.appendChild(btn);
      ordersBody.appendChild(tr);
    }
  } catch (err) {
    showError('orders load failed', err.message);
    ordersBody.innerHTML = '';
    ordersBody.appendChild(rowEmpty(7, 'load failed - see banner'));
  }
}

async function deleteOrder(id) {
  try {
    await apiCall('DELETE', `/api/v1/orders/${id}`);
    clearError();
    await loadOrders();
  } catch (err) {
    showError('delete failed', err.message);
  }
}

async function createOrder(ev) {
  ev.preventDefault();
  orderResult.classList.add('hidden');
  const fd = new FormData(ev.target);
  const body = {
    item_id: fd.get('item_id'),
    quantity: parseInt(fd.get('quantity'), 10),
  };
  try {
    const created = await apiCall('POST', '/api/v1/orders', body);
    clearError();
    orderResult.classList.remove('hidden');
    orderResult.classList.add('ok');
    orderResult.textContent = `created order ${created.id} - ${created.quantity} x ${created.item_name} @ ${formatMoney(created.unit_price)} ${created.currency} = ${formatMoney(created.total)} ${created.currency}`;
    await Promise.all([loadInventory(), loadOrders()]);
  } catch (err) {
    orderResult.classList.remove('hidden');
    orderResult.classList.remove('ok');
    orderResult.textContent = `create failed: ${err.message}`;
  }
}

async function refreshHealth() {
  for (const [id, url] of [['#status-goapi', '/health/goapi'], ['#status-rust', '/health/rust']]) {
    const el = document.querySelector(id);
    try {
      const resp = await fetch(url);
      const ok = resp.ok;
      el.classList.toggle('ok', ok);
      el.classList.toggle('bad', !ok);
      el.querySelector('em').textContent = ok ? 'ready' : `not ready (${resp.status})`;
    } catch (err) {
      el.classList.remove('ok');
      el.classList.add('bad');
      el.querySelector('em').textContent = 'unreachable';
    }
  }
}

function escape(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function formatMoney(n) {
  if (n === null || n === undefined) return '';
  return Number(n).toFixed(2);
}

function formatTime(iso) {
  if (!iso) return '';
  try { return new Date(iso).toLocaleString(); } catch (_) { return iso; }
}

document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('button.refresh').forEach((b) => {
    b.addEventListener('click', () => {
      clearError();
      if (b.dataset.target === 'inventory') loadInventory();
      if (b.dataset.target === 'orders') loadOrders();
    });
  });
  document.getElementById('order-form').addEventListener('submit', createOrder);
  refreshHealth();
  setInterval(refreshHealth, 10000);
  loadInventory();
  loadOrders();
});
