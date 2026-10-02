#!/usr/bin/env python3
"""Synthetic flights for the ground replays (AeroCheckUITests, GroundReplay.swift).

Each scenario is a deterministic, realistic GPS track of the bundled WT9 Dynamic (F-HVXA, Vso 33 kt,
Vr 40 kt) between real Swiss aerodromes: parked, taxi, holding point, line-up, take-off roll and
rotation, climb, level-off, cruise legs, descent, circuit, touchdown, rollout, taxi and stop, with
GPS-like noise (position, altitude and speed, correlated from one second to the next). One fix a
second, as CoreLocation delivers them.

The app's own referee says what each flight should do: when the Python prototype of the flight-event
detector and its cues (detector_v2.py, outside the repo on the author's Mac) is found, every scenario
is replayed through it the way the app feeds its detector (the scenario's aerodromes only, one fix
every 5 s of the replay's clock, nothing before ENGINE START, the holds at their nominal length), and
the expected landings, take-offs and cues are written into the scenario. Without the referee the
expectations already in the file are kept.

    python3 scripts/flightsim/make_scenario.py                  # every scenario, into AeroCheckUITests/Scenarios
    python3 scripts/flightsim/make_scenario.py xc-all-checks    # one
    python3 scripts/flightsim/make_scenario.py --check          # regenerate in memory, fail if a file differs

Python 3 standard library only.
"""
import argparse
import csv
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
OUT_DIR = os.path.join(REPO, 'AeroCheckUITests', 'Scenarios')
REFEREE_DIR = os.environ.get('AEROCHECK_REFEREE',
                             os.path.abspath(os.path.join(REPO, '..', 'CLAUDE', 'review', 'flight-events')))

KT = 0.514444          # m/s per knot
FT = 0.3048            # m per foot
NM = 1852.0            # m per nautical mile
EARTH_R = 6371000.0
FIXED_WING = ('small_airport', 'medium_airport', 'large_airport')

# The WT9 Dynamic as the bundled checklist gives it (wt9-dynamic-bundled.json).
WT9 = dict(registration='F-HVXA', vso=33, vr=40, vy=70, cruise=100, descent=105, downwind=80, base=70,
           final=63, touchdown=50, taxi=9)

# Aerodromes (OurAirports, as airports.csv and the app's data have them) and the runway each scenario uses:
# true heading of the landing / take-off direction, length, the side of the circuit and its height above
# the field. The runway is laid out centred on the reference point.
AERODROMES = {
    'LSZQ': dict(name='Bressaucourt Airfield', lat=47.392408, lon=7.028956, elev=1866, type='small_airport',
                 rwy=232.0, length=800, circuit='L', tpa=1000),
    'LSGC': dict(name='Les Eplatures Airport', lat=47.0839004517, lon=6.79284000397, elev=3368, type='medium_airport',
                 rwy=241.0, length=1130, circuit='R', tpa=1000),
    'LSGN': dict(name='Neuchâtel Airfield', lat=46.957371, lon=6.864574, elev=1427, type='small_airport',
                 rwy=230.0, length=700, circuit='R', tpa=1000),
    'LSZB': dict(name='Bern Airport', lat=46.912736, lon=7.498819, elev=1671, type='medium_airport',
                 rwy=320.0, length=1730, circuit='L', tpa=1000),
    'LSZG': dict(name='Grenchen Airfield', lat=47.181599, lon=7.41719, elev=1411, type='medium_airport',
                 rwy=247.0, length=1000, circuit='L', tpa=1000),
    'LSZJ': dict(name='Courtelary Airfield', lat=47.183374, lon=7.09085, elev=2247, type='small_airport',
                 rwy=255.0, length=600, circuit='L', tpa=1000),
    'LSZP': dict(name='Biel-Kappelen Airfield', lat=47.088242, lon=7.289055, elev=1437, type='small_airport',
                 rwy=265.0, length=600, circuit='L', tpa=1000),
}


# ---------------------------------------------------------------------------------------------------
# Geometry (spherical Earth, plenty for a few tens of NM)

def destination(lat, lon, bearing_deg, dist_m):
    p1, l1, b = math.radians(lat), math.radians(lon), math.radians(bearing_deg)
    d = dist_m / EARTH_R
    p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(b))
    l2 = l1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * math.sin(p2))
    return math.degrees(p2), (math.degrees(l2) + 540) % 360 - 180


def distance(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = math.radians(lat2 - lat1), math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R * math.asin(min(1.0, math.sqrt(a)))


def bearing(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def angle_diff(a, b):
    """b - a, in -180...180."""
    return (b - a + 540) % 360 - 180


class Field:
    """An aerodrome and the points of its circuit for the runway in use."""

    def __init__(self, ident):
        a = AERODROMES[ident]
        self.ident, self.name, self.lat, self.lon = ident, a['name'], a['lat'], a['lon']
        self.elev, self.type, self.rwy, self.length = a['elev'], a['type'], a['rwy'], a['length']
        self.side = -1 if a['circuit'] == 'L' else 1      # left circuit: the downwind is left of the runway
        self.tpa = self.elev + a['tpa']

    def point(self, along_m, right_m=0.0):
        """A point `along_m` along the runway direction from the reference point, `right_m` to its right."""
        lat, lon = destination(self.lat, self.lon, self.rwy, along_m)
        if right_m:
            lat, lon = destination(lat, lon, self.rwy + 90, right_m)
        return lat, lon

    @property
    def threshold(self):
        return self.point(-self.length / 2 + 60)

    @property
    def runway_end(self):
        return self.point(self.length / 2)

    def apron(self):
        return self.point(-self.length / 4, -self.side * 140)

    def holding_point(self):
        return self.point(-self.length / 2 + 40, -self.side * 70)

    def circuit_point(self, name):
        """downwind start / end, base, final (1.4 NM out), in the circuit's side."""
        off = self.side * 0.9 * NM
        return {
            'crosswind': self.point(self.length / 2 + 0.6 * NM, 0),
            'downwindStart': self.point(self.length / 2 + 0.3 * NM, off),
            'downwindEnd': self.point(-self.length / 2 - 0.7 * NM, off),
            'base': self.point(-self.length / 2 - 1.6 * NM, off * 0.55),
            'final': self.point(-self.length / 2 - 1.5 * NM, 0),
        }[name]


# ---------------------------------------------------------------------------------------------------
# The aircraft, one second at a time

class Flight:
    def __init__(self, seed, field, aircraft=WT9):
        self.rng = random.Random(seed)
        self.ac = aircraft
        self.field = field
        self.lat, self.lon = field.apron()
        self.alt = field.elev          # feet MSL, true
        self.spd = 0.0                 # knots
        self.hdg = (field.rwy + 90) % 360
        self.t = 0
        self.rows = []
        self.holds = []
        self.marks = {}                # name -> t, for the UI tests' timing
        # GPS errors: a bias and slowly wandering noise (AR(1)), as a phone's GPS shows them.
        self.alt_bias_m = 3.5
        self.e_alt = self.e_n = self.e_e = 0.0

    # -- output
    def emit(self):
        r = self.rng
        self.e_alt = 0.92 * self.e_alt + r.gauss(0, 0.6)
        self.e_n = 0.9 * self.e_n + r.gauss(0, 0.45)
        self.e_e = 0.9 * self.e_e + r.gauss(0, 0.45)
        lat, lon = destination(self.lat, self.lon, 0, self.e_n)
        lat, lon = destination(lat, lon, 90, self.e_e)
        alt_m = self.alt * FT + self.alt_bias_m + self.e_alt
        speed = max(0.0, self.spd * KT + r.gauss(0, 0.15)) if self.spd > 0.3 else round(abs(r.gauss(0, 0.05)), 2)
        hacc = round(3.5 + abs(r.gauss(0, 0.8)) + (1.5 if self.spd < 1 else 0), 1)
        course = round(self.hdg % 360, 1) if self.spd >= 2 else -1
        self.rows.append([self.t, round(lat, 6), round(lon, 6), round(alt_m, 1), round(speed, 2), hacc, course])
        self.t += 1

    def mark(self, name):
        """Where the UI tests can expect something: 'liftoff', then 'liftoff2' for the next one."""
        key, n = name, 1
        while key in self.marks:
            n += 1
            key = f'{name}{n}'
        self.marks[key] = self.t

    def hold(self, until, at=None):
        self.holds.append(dict(t=self.t if at is None else at, until=until))

    # -- primitives
    def step(self, target_spd, accel=1.5, vs_fpm=0.0, target_hdg=None, turn_rate=3.0):
        if target_hdg is not None:
            d = angle_diff(self.hdg, target_hdg)
            self.hdg = (self.hdg + max(-turn_rate, min(turn_rate, d))) % 360
        if self.spd < target_spd:
            self.spd = min(target_spd, self.spd + accel)
        else:
            self.spd = max(target_spd, self.spd - accel)
        self.alt += vs_fpm / 60.0
        self.lat, self.lon = destination(self.lat, self.lon, self.hdg, self.spd * KT)
        self.emit()

    def park(self, seconds):
        self.spd = 0.0
        for _ in range(int(seconds)):
            self.emit()

    def go_to(self, point, spd, alt=None, vs_fpm=500.0, accel=1.5, arrive_m=None, turn_rate=3.0, climb_spd=None,
              level_mark=None):
        """Fly (or taxi) to `point` at `spd`, climbing or descending towards `alt` at up to `vs_fpm`; at
        `climb_spd` while more than 50 ft below `alt`. `level_mark`: marked when `alt` is reached."""
        lat2, lon2 = point
        arrive = arrive_m if arrive_m is not None else max(15.0, spd * KT * 1.2)
        # In the air a point is passed rather than hit: arrived once within 0.4 NM and opening again.
        passing = 0.4 * NM if spd > 30 else 0.0
        previous = None
        for _ in range(4 * 3600):
            d = distance(self.lat, self.lon, lat2, lon2)
            if d <= arrive or (previous is not None and d < passing and d > previous):
                return
            previous = d
            vs = 0.0
            target = spd
            if alt is not None:
                gap = alt - self.alt
                vs = max(-vs_fpm, min(vs_fpm, gap * 6.0))   # eases into the level over the last ~80 ft
                if climb_spd and gap > 50:
                    target = climb_spd
                if level_mark and abs(gap) < 5 and level_mark not in self.marks:
                    self.mark(level_mark)
            self.step(target, accel=accel, vs_fpm=vs, target_hdg=bearing(self.lat, self.lon, lat2, lon2),
                      turn_rate=turn_rate)
        raise RuntimeError('go_to never arrived')

    def fly(self, seconds, spd, alt=None, vs_fpm=500.0, hdg=None):
        for _ in range(int(seconds)):
            vs = 0.0
            if alt is not None:
                vs = max(-vs_fpm, min(vs_fpm, (alt - self.alt) * 6.0))
            self.step(spd, vs_fpm=vs, target_hdg=hdg)

    def climb_to(self, alt, spd, toward, vs_fpm=700.0):
        """Climb towards `toward` until `alt`, then go on level at `spd`."""
        while self.alt < alt - 5:
            vs = max(150.0, min(vs_fpm, (alt - self.alt) * 6.0))
            self.step(spd, vs_fpm=vs, target_hdg=bearing(self.lat, self.lon, *toward))
        self.alt = alt if abs(self.alt - alt) < 5 else self.alt

    # -- ground
    def taxi_to(self, point, spd=None):
        self.go_to(point, spd or self.ac['taxi'], accel=1.0, arrive_m=8, turn_rate=12)
        self.spd = 0.0

    def line_up_and_take_off(self, field, climb_to_ft, toward, mark_level=True):
        """From the holding point onto the runway, the roll, rotation at Vr, and the climb at Vy."""
        self.mark('lineUp')
        self.taxi_to(field.point(-field.length / 2 + 20), spd=6)
        self.hdg = field.rwy
        self.park(8)
        self.mark('takeoffRoll')
        while self.spd < self.ac['vr'] + 6:                  # ~2.4 kt/s
            self.step(self.ac['vr'] + 6, accel=2.4, target_hdg=field.rwy)
        self.mark('liftoff')
        for _ in range(20):                                 # rotation, initial climb accelerating to Vy
            self.step(self.ac['vy'], accel=1.2, vs_fpm=550, target_hdg=field.rwy)
        self.climb_to(climb_to_ft, self.ac['vy'], toward)
        if mark_level:
            self.mark('levelOff')

    # -- the circuit
    def circuit(self, field, ending, join_alt=None, stop_seconds=20, upwind=False, hold_at_stop=None):
        """Downwind, base, final and the landing: 'fullStop' (stop, then the exit), 'touchAndGo', 'stopAndGo'.
        `upwind`: fly the crosswind first (after a take-off from this field). `hold_at_stop`: the replay
        waits on the runway, stopped, until that holds (a stop-and-go's card answered and the checks done
        again: at 10x its 20 s stop leaves the pilot two seconds)."""
        tpa = join_alt or field.tpa
        if upwind:
            self.go_to(field.circuit_point('crosswind'), self.ac['vy'], alt=tpa, vs_fpm=650)
        self.go_to(field.circuit_point('downwindStart'), self.ac['downwind'], alt=tpa, vs_fpm=650)
        self.mark('downwind')
        self.go_to(field.circuit_point('downwindEnd'), self.ac['downwind'], alt=tpa)
        self.go_to(field.circuit_point('base'), self.ac['base'], alt=field.elev + 650, vs_fpm=500)
        self.mark('base')
        self.go_to(field.circuit_point('final'), self.ac['final'], alt=field.elev + 450, vs_fpm=500)
        self.mark('final')
        thr = field.threshold
        # Final at ~3°: 63 kt and ~340 fpm down to the threshold, the flare over the first 200 m.
        while distance(self.lat, self.lon, *thr) > 40:
            d = distance(self.lat, self.lon, *thr)
            height = max(0.0, self.alt - field.elev)
            vs = -min(420.0, max(120.0, height / max(d / (self.spd * KT), 1.0) * 60.0))
            self.step(self.ac['final'], accel=0.8, vs_fpm=vs, target_hdg=bearing(self.lat, self.lon, *thr))
        while self.alt > field.elev + 0.5:
            self.step(self.ac['touchdown'], accel=1.5, vs_fpm=-max(60.0, (self.alt - field.elev) * 20),
                      target_hdg=field.rwy)
        self.alt = field.elev
        self.mark('touchdown')
        if ending == 'touchAndGo':
            for _ in range(12):                             # on the wheels, flaps up, power
                self.step(self.ac['vr'] + 2, accel=1.2, target_hdg=field.rwy)
            while self.spd < self.ac['vr'] + 8:
                self.step(self.ac['vr'] + 8, accel=2.4, target_hdg=field.rwy)
            self.mark('liftoff')
            for _ in range(20):
                self.step(self.ac['vy'], accel=1.2, vs_fpm=550, target_hdg=field.rwy)
            return
        # Rollout to a stop on the runway, wait, then off it (full stop) or away again (stop-and-go).
        while self.spd > 0.5:
            self.step(0, accel=3.0, target_hdg=field.rwy)
        self.spd = 0
        self.mark('stopped')
        if hold_at_stop:
            self.hold(hold_at_stop)
        self.park(stop_seconds)
        if ending == 'stopAndGo':
            self.mark('takeoffRoll')
            while self.spd < self.ac['vr'] + 6:
                self.step(self.ac['vr'] + 6, accel=2.4, target_hdg=field.rwy)
            self.mark('liftoff')
            for _ in range(20):
                self.step(self.ac['vy'], accel=1.2, vs_fpm=550, target_hdg=field.rwy)
            return
        exit_point = field.point(distance(field.lat, field.lon, self.lat, self.lon)
                                 * (1 if abs(angle_diff(field.rwy, bearing(field.lat, field.lon, self.lat, self.lon))) < 90 else -1),
                                 -field.side * 60)
        self.taxi_to(exit_point, spd=8)
        self.mark('vacated')


# ---------------------------------------------------------------------------------------------------
# The scenarios

def scenario_xc(name, seed, dep, dest, waypoints, cruise_ft, *, description, level_dip=None, planned=False):
    """A cross-country flight with a route: dep → waypoints → dest. `waypoints`: [(name, lat, lon, kind, aerodrome)].
    `level_dip`: (after_waypoint_index, seconds_into_leg) to start down 600 ft, level, and climb back.
    `planned`: the route is a flight planned for today (Plan new flight), not a route alone."""
    d, a = Field(dep), Field(dest)
    f = Flight(seed, d)
    f.hold('engineStart', at=0)
    f.park(45)                                     # after engine start, before taxi
    f.taxi_to(d.holding_point())
    f.park(30)                                     # run-up
    f.hold('lineUp')
    f.park(20)
    first = (waypoints[0][1], waypoints[0][2]) if waypoints else (a.lat, a.lon)
    # The initial climb straight on to 800 ft above the field, then the route, climbing to the cruise.
    f.line_up_and_take_off(d, d.elev + 800, d.point(d.length / 2 + 1.5 * NM), mark_level=False)
    route = [(wp[1], wp[2]) for wp in waypoints] + [a.circuit_point('downwindStart')]
    descent_from = a.tpa
    for i, point in enumerate(route):
        last = i == len(route) - 1
        if last:
            # Descend to circuit height from ~9 NM out: the descent cue well before the approach (5 NM).
            dist = distance(f.lat, f.lon, *point)
            top = destination(f.lat, f.lon, bearing(f.lat, f.lon, *point), max(0.0, dist - 9 * NM))
            f.go_to(top, WT9['cruise'], alt=cruise_ft, vs_fpm=700, climb_spd=WT9['vy'], level_mark='levelOff')
            f.mark('topOfDescent')
            f.go_to(point, WT9['descent'], alt=descent_from, vs_fpm=550)
        else:
            f.go_to(point, WT9['cruise'], alt=cruise_ft, vs_fpm=700, climb_spd=WT9['vy'], level_mark='levelOff')
            f.mark(f'wp{i + 1}')
            if level_dip and level_dip[0] == i:
                hdg = f.hdg
                f.fly(level_dip[1], WT9['cruise'], alt=cruise_ft, hdg=hdg)
                f.mark('dipStart')
                f.fly(80, WT9['cruise'], alt=cruise_ft - 600, vs_fpm=500, hdg=hdg)
                f.fly(60, WT9['cruise'], alt=cruise_ft - 600, hdg=hdg)
                f.mark('dipClimb')
                f.fly(110, WT9['vy'] + 10, alt=cruise_ft + 100, vs_fpm=500, hdg=hdg)
                f.fly(40, WT9['cruise'], alt=cruise_ft + 100, hdg=hdg)
                cruise_ft += 100
    f.circuit(a, 'fullStop')
    f.taxi_to(a.apron())
    f.park(90)
    route_json = dict(name=f'{dep} → {dest}', departureInMinutes=60, waypoints=(
        [dict(name=dep, lat=d.lat, lon=d.lon, kind='aerodrome')]
        + [dict(name=w[0], lat=w[1], lon=w[2], altitude=cruise_ft, kind=w[3], **({'aerodrome': w[4]} if w[4] else {}))
           for w in waypoints]
        + [dict(name=dest, lat=a.lat, lon=a.lon, kind='aerodrome')]))
    if planned:
        route_json['planned'] = True
    return f, dict(name=name, description=description, departure=dep, destination=dest, route=route_json,
                   circuits=False)


def scenario_local(name, seed, field_id, *, description, laps, cruise_ft=None, circuits=True, hold_first_stop=None):
    """Circuits (`laps`: the endings, the last a full stop), or with `cruise_ft` a short local flight first.
    `hold_first_stop`: the first stop-and-go waits for it (`Flight.circuit`'s `hold_at_stop`)."""
    fld = Field(field_id)
    f = Flight(seed, fld)
    f.hold('engineStart', at=0)
    f.park(45)
    f.taxi_to(fld.holding_point())
    f.park(30)
    f.hold('lineUp')
    f.park(20)
    if cruise_ft:
        out = destination(fld.lat, fld.lon, fld.rwy, 7 * NM)
        f.line_up_and_take_off(fld, cruise_ft, out)
        f.go_to(out, WT9['cruise'], alt=cruise_ft)
        f.fly(150, WT9['cruise'], alt=cruise_ft, hdg=(fld.rwy + 120) % 360)
        f.mark('topOfDescent')
        f.go_to(fld.circuit_point('downwindStart'), WT9['descent'], alt=fld.tpa, vs_fpm=550)
        first_upwind = False
    else:
        f.line_up_and_take_off(fld, fld.elev + 500, fld.point(fld.length / 2 + 2 * NM))
        first_upwind = True
    first_stop = laps.index('stopAndGo') if 'stopAndGo' in laps else None
    for i, ending in enumerate(laps):
        f.mark(f'lap{i + 1}')
        f.circuit(fld, ending, upwind=first_upwind or i > 0,
                  hold_at_stop=hold_first_stop if i == first_stop else None)
        if ending == 'fullStop' and i < len(laps) - 1:
            # Off the runway, back to the holding point (the landed card left unanswered), and away again.
            f.taxi_to(fld.holding_point())
            f.park(25)
            f.mark('secondDeparture')
            f.line_up_and_take_off(fld, fld.elev + 500, fld.point(fld.length / 2 + 2 * NM))
    f.taxi_to(fld.apron())
    f.park(90)
    return f, dict(name=name, description=description, departure=field_id, destination=field_id, route=None,
                   circuits=circuits)


def build(name):
    LSZQ, LSGC = Field('LSZQ'), Field('LSGC')
    if name == 'xc-all-checks':
        # LSZQ → LSGC by a turning point 7 min after the level-off (FREDA at a waypoint), then 11 min on.
        return scenario_xc(name, 101, 'LSZQ', 'LSGC',
                           [('INS', 47.0240, 7.1620, 'user', None)], 5500,
                           description='Cross-country LSZQ → INS → LSGC, every check on time')
    if name == 'xc-planned':
        # The same flight as xc-all-checks, planned for an hour after the replay starts: the ETOs.
        return scenario_xc(name, 101, 'LSZQ', 'LSGC',
                           [('INS', 47.0240, 7.1620, 'user', None)], 5500, planned=True,
                           description='LSZQ → INS → LSGC planned for today, an hour on: the ETOs from the plan, then the take-off')
    if name == 'xc-climb-owed':
        return scenario_xc(name, 102, 'LSZQ', 'LSGC',
                           [('INS', 47.0240, 7.1620, 'user', None)], 5500,
                           description='Cross-country LSZQ → INS → LSGC: the climb check left open through the level-off')
    if name == 'xc-freda-missed':
        # Long enough in cruise for FREDA to come due by the clock (10 min) before the descent.
        return scenario_xc(name, 103, 'LSZQ', 'LSGC',
                           [('BIEL', 47.1360, 7.2470, 'user', None)], 5500,
                           description='Cross-country LSZQ → BIEL → LSGC: FREDA due, cruise left without it')
    if name == 'xc-descent-abandoned':
        return scenario_xc(name, 104, 'LSZQ', 'LSGC',
                           [('INS', 47.0240, 7.1620, 'user', None)], 5500, level_dip=(0, 60),
                           description='Cross-country LSZQ → INS → LSGC: a descent started, levelled, climbed back')
    if name == 'local-landed-unanswered':
        return scenario_local(name, 105, 'LSZQ', laps=['fullStop', 'fullStop'], cruise_ft=4000, circuits=False,
                              description='Local flight at LSZQ: full stop, card left unanswered, taxi, away again, full stop')
    if name == 'circuits-stop-and-go':
        # The first stop-and-go waits for its card to be answered and the checks to the line-up done again
        # (circuits-2); the second goes on unanswered, its card gone on the roll (circuits-3).
        return scenario_local(name, 106, 'LSZQ', laps=['touchAndGo', 'stopAndGo', 'stopAndGo', 'fullStop'],
                              hold_first_stop='phaseIs:lineUp',
                              description='Circuits at LSZQ: a touch-and-go, two stop-and-goes, a full stop')
    if name == 'route-vrps':
        # LSGN → E (LSGC) → LSZQ: reporting points on the way, the waypoint marking of 6.0.1.
        return scenario_xc(name, 107, 'LSGN', 'LSZQ',
                           [('N', 47.0300, 6.8900, 'vrp', 'LSGN'),
                            ('E', 47.1050, 6.8650, 'vrp', 'LSGC'),
                            ('SAIGNELEGIER', 47.2560, 6.9970, 'user', None),
                            ('ST-URSANNE', 47.3640, 7.1550, 'user', None)], 4500,
                           description='LSGN → N (LSGN) → E (LSGC) → SAIGNELEGIER → ST-URSANNE → LSZQ, waypoints marked from GPS')
    raise SystemExit(f'unknown scenario {name}')


ALL = ['xc-all-checks', 'xc-planned', 'xc-climb-owed', 'xc-freda-missed', 'xc-descent-abandoned', 'local-landed-unanswered',
       'circuits-stop-and-go', 'route-vrps']


# ---------------------------------------------------------------------------------------------------
# The aerodromes the app gets, and the referee

def nearby_aerodromes(rows, extra):
    """Every fixed-wing aerodrome within 6 NM of the track, as make_fixtures.py gathers them: from the
    referee's airports.csv when it is here, else the table above."""
    pool = []
    csv_path = os.path.join(REFEREE_DIR, 'airports.csv')
    lats = [r[1] for r in rows]
    lons = [r[2] for r in rows]
    box = (min(lats) - 0.2, max(lats) + 0.2, min(lons) - 0.3, max(lons) + 0.3)
    if os.path.exists(csv_path):
        with open(csv_path, newline='', encoding='utf-8') as fh:
            for r in csv.DictReader(fh):
                if r['type'] not in FIXED_WING:
                    continue
                try:
                    lat, lon = float(r['latitude_deg']), float(r['longitude_deg'])
                except ValueError:
                    continue
                if box[0] <= lat <= box[1] and box[2] <= lon <= box[3]:
                    elev = int(float(r['elevation_ft'])) if r['elevation_ft'] else None
                    pool.append(dict(ident=r['ident'], name=r['name'], lat=lat, lon=lon, elev=elev, type=r['type']))
    else:
        pool = [dict(ident=k, name=v['name'], lat=v['lat'], lon=v['lon'], elev=v['elev'], type=v['type'])
                for k, v in AERODROMES.items()]
    keep = {}
    for r in rows[::20]:
        for a in pool:
            if distance(r[1], r[2], a['lat'], a['lon']) <= 6 * NM:
                keep[a['ident']] = a
    for ident in extra:
        a = next((x for x in pool if x['ident'] == ident), None)
        if a:
            keep[ident] = a
    # The table's values for the scenario's own fields, so the runway and the elevation agree.
    for ident, a in keep.items():
        if ident in AERODROMES:
            t = AERODROMES[ident]
            if abs(t['lat'] - a['lat']) > 0.01 or abs(t['lon'] - a['lon']) > 0.01 or (a['elev'] and abs(t['elev'] - a['elev']) > 30):
                raise SystemExit(f'{ident}: the table disagrees with airports.csv ({a})')
    return sorted(keep.values(), key=lambda a: a['ident'])


# Nominal holds for the referee: how long the pilot keeps the replay waiting, in replay seconds.
NOMINAL_HOLD = {'engineStart': 120, 'lineUp': 150, 'phaseIs:lineUp': 150}


def referee(track, holds, airports, aircraft, destination_point, circuits):
    """The expected landings, take-offs and cues, from detector_v2 fed as the app feeds its detector.
    Times in track seconds. None when the referee isn't on this machine."""
    if not os.path.exists(os.path.join(REFEREE_DIR, 'detector_v2.py')):
        return None
    sys.path.insert(0, REFEREE_DIR)
    from datetime import datetime, timezone
    from detector_v2 import V2

    def fw_nearest(lat, lon):
        near = sorted(((distance(lat, lon, a['lat'], a['lon']) / NM, a) for a in airports
                       if a['type'] in FIXED_WING), key=lambda x: x[0])
        return [a for d, a in near if d <= 5.0][:3]

    det = V2(aircraft['vso'], aircraft['vr'], destination=None if circuits else destination_point)
    epoch = 1_800_000_000.0
    virtual = 0.0           # replay seconds since the start
    offset = 0.0            # virtual - track time
    last_det = None
    engine_started = False
    to_track = []           # (virtual, track) pairs at each hold, to map times back
    hold_at = {h['t']: h['until'] for h in holds}
    for row in track:
        t = row[0]
        if t in hold_at:
            until = hold_at.pop(t)
            dur = NOMINAL_HOLD.get(until, 60)
            # Held: the same fix again once a second, the detector fed every 5 s once the engine runs.
            for k in range(int(dur)):
                v = t + offset + k
                if engine_started and (last_det is None or v - last_det >= 5):
                    last_det = v
                    det.process(datetime.fromtimestamp(epoch + v, tz=timezone.utc), row[1], row[2], row[3],
                                row[4] if row[4] >= 0 else None, fw_nearest(row[1], row[2]))
            to_track.append((t + offset, t, dur))
            offset += dur
            if until == 'engineStart':
                engine_started = True
        v = t + offset
        speed_kt = row[4] / KT
        if (engine_started or speed_kt > 30) and (last_det is None or v - last_det >= 5):
            last_det = v
            det.process(datetime.fromtimestamp(epoch + v, tz=timezone.utc), row[1], row[2], row[3],
                        row[4] if row[4] >= 0 else None, fw_nearest(row[1], row[2]))

    def track_time(dt):
        v = dt.timestamp() - epoch
        shift = 0.0
        for (hv, ht, dur) in to_track:
            if v >= hv + dur:
                shift += dur
            elif v >= hv:
                return ht
        return round(v - shift, 1)

    events = [dict(type=k, t=track_time(tt), at=ident) for (tt, k, ident) in det.events]
    takeoffs = [track_time(tt) for tt in det.takeoffs]
    cues = [dict(type=k, t=track_time(tt), implied=imp, at=ident) for (tt, k, imp, ident) in det.cues.events]
    return dict(events=events, takeoffs=takeoffs, cues=cues,
                referee='detector_v2.py + FlightCues, fed one fix every 5 s of the replay clock, holds '
                        + ', '.join(f'{k} {v} s' for k, v in NOMINAL_HOLD.items()
                                    if k in ('engineStart', 'lineUp') or any(h['until'] == k for h in holds)))


def make(name, previous=None):
    f, meta = build(name)
    rows = f.rows
    route = meta['route']
    extra = [meta['departure'], meta['destination']]
    airports = nearby_aerodromes(rows, extra)
    dest = None
    if route and not meta['circuits']:
        dest = (route['waypoints'][-1]['lat'], route['waypoints'][-1]['lon'])
    expected = referee(rows, f.holds, airports, WT9, dest, meta['circuits'])
    if expected is None:
        expected = (previous or {}).get('expected')
        print(f'  {name}: referee not found at {REFEREE_DIR}; expectations kept from the file', file=sys.stderr)
    scenario = dict(
        name=name,
        description=meta['description'],
        generator='scripts/flightsim/make_scenario.py',
        registration=WT9['registration'],
        aircraft=dict(vso=WT9['vso'], vr=WT9['vr']),
        speedFactor=10,
        circuits=meta['circuits'],
        departure=meta['departure'],
        destination=meta['destination'],
        fieldElevations={a['ident']: a['elev'] for a in airports},
        marks=f.marks,
        holds=f.holds,
        expected=expected,
        airports=airports,
        route=route,
        track=rows,
    )
    if route is None:
        del scenario['route']
    return scenario


def dump(scenario):
    """One track row per line: readable diffs, small files."""
    head = {k: v for k, v in scenario.items() if k != 'track'}
    text = json.dumps(head, ensure_ascii=False, indent=1)[:-2]
    rows = ',\n'.join(json.dumps(r, separators=(',', ':')) for r in scenario['track'])
    return text + ',\n "track": [\n' + rows + '\n ]\n}\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('names', nargs='*', help='scenarios to build (default: all)')
    ap.add_argument('--out', default=OUT_DIR)
    ap.add_argument('--check', action='store_true', help='fail if a committed scenario differs from a fresh build')
    ap.add_argument('--summary', action='store_true', help='print the expected events and cues')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    bad = 0
    for name in args.names or ALL:
        path = os.path.join(args.out, name + '.json')
        previous = json.load(open(path)) if os.path.exists(path) else None
        scenario = make(name, previous)
        text = dump(scenario)
        if args.check:
            if not os.path.exists(path) or open(path).read() != text:
                print(f'{name}: differs from a fresh build')
                bad += 1
            continue
        with open(path, 'w') as fh:
            fh.write(text)
        e = scenario['expected'] or {}
        mins = scenario['track'][-1][0] / 60
        print(f'{name}: {len(scenario["track"])} fixes, {mins:.1f} min, '
              f'events {[x["type"] for x in e.get("events", [])]}, '
              f'cues {[x["type"] for x in e.get("cues", []) if not x["implied"]]}')
        if args.summary:
            print('   marks', scenario['marks'])
            print('   holds', scenario['holds'])
            for x in e.get('events', []):
                print('   event', x)
            for x in e.get('cues', []):
                print('   cue  ', x)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
