  .pragma library

var SEP = " -_./";

function lower(s) {
  return s ? String(s).toLowerCase() : "";
}

function buildRecords(text) {
  var out = [];

  if (!text) return out;

  var lines = String(text).split("\n");

  for (var i = 0; i < lines.length; i++) {
    var l = lines[i];
    var t = l.indexOf("\t");

    if (!l || t < 0) continue;

    var id = l.substring(0, t);
    var p = l.substring(t + 1);
    var img = p.indexOf("[[ binary data") === 0;
    var name = p;

    if (img) {
      var m = /binary data ([\d.]+ \w+) (\w+) (\d+x\d+)/.exec(p);

      name = m
        ? "Image  " + m[3] + "  " + m[2] + "  " + m[1]
        : "Image";
    }

    out.push({
      id: id,
      name: name,
      raw: l,
      img: img,
      lname: lower(name),
      i: out.length
    });
  }

  return out;
}

function fuzzy(q, t) {
  var qi = 0;
  var score = 0;
  var prev = -2;

  for (var ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t.charAt(ti) === q.charAt(qi)) {
      score += 1;

      if (ti === prev + 1) score += 2;
      if (ti === 0 || SEP.indexOf(t.charAt(ti - 1)) >= 0) {
        score += 3;
      }

      prev = ti;
      qi++;
    }
  }

  return qi === q.length ? 50 + score : 0;
}

function field(q, t) {
  if (!t) return 0;
  if (t === q) return 1000;

  var idx = t.indexOf(q);

  if (idx === 0) {
    return 800 - Math.min(t.length, 100) * 0.5;
  }

  if (idx > 0) {
    return (SEP.indexOf(t.charAt(idx - 1)) >= 0 ? 600 : 400) - idx;
  }

  return fuzzy(q, t);
}

function run(records, query, limit) {
  var tokens = lower(query)
    .trim()
    .split(/\s+/)
    .filter(function(t) {
    return t !== "";
  });

  var scored = [];

  for (var i = 0; i < records.length; i++) {
    var r = records[i];
    var s = 0;

    if (tokens.length > 0) {
      var ok = true;

      for (var j = 0; j < tokens.length; j++) {
        var ts = field(tokens[j], r.lname);

        if (ts <= 0) {
          ok = false;
          break;
        }

        s += ts;
      }

      if (!ok) continue;
    }

    scored.push({ r: r, s: s });
  }

  scored.sort(function(a, b) {
    if (b.s !== a.s) return b.s - a.s;

    return a.r.i - b.r.i;
  });

  var out = [];

  for (var k = 0; k < scored.length && k < limit; k++) {
    out.push(scored[k].r);
  }

  return out;
}
