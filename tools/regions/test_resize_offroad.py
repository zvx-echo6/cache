import json
import unittest

import resize_offroad as r


def pack(pid, name, country, bbox, nbytes):
    return {"id": pid, "name": name, "country": country, "bbox": bbox, "files": {"offroad.sqlite": {"bytes": nbytes}}}


# two states side by side: the pack boxes are the states plus a margin, so they overlap at the line (lon -115)
PACKS = [pack("idaho", "Idaho", "US", [-118.0, 41.0, -110.0, 50.0], 100), pack("nevada", "Nevada", "US", [-121.0, 34.0, -114.0, 43.0], 200)]


def rec(rid, name, kind, bbox, parents=(), country="US"):
    return {"id": rid, "name": name, "kind": kind, "country": country, "parents": list(parents), "bbox": bbox, "sizes": {"offroad": {"packs": {}, "terrain": 7}}}


def shard(*records):
    return {"format": 1, "regions": list(records)}


class Rule(unittest.TestCase):
    def test_a_county_on_a_state_line_gets_its_own_states_pack_only(self):
        # a county in Idaho at the Nevada line: the Nevada pack's box holds it and is the smaller one, Idaho's holds it too
        county = rec("us-id-x-county", "X County", "county", [-115.0, 41.5, -114.5, 42.0], ["us-id"])
        s = shard(rec("us-id", "Idaho", "region", [-117.2, 42.0, -111.0, 49.0]), county)
        _, changes = r.resize(s, PACKS, old_rule=True)
        self.assertEqual(s["regions"][1]["sizes"]["offroad"]["packs"], {"nevada": 200}, "the old rule: the smallest box holding it")
        s = shard(rec("us-id", "Idaho", "region", [-117.2, 42.0, -111.0, 49.0]), rec("us-id-x-county", "X County", "county", [-115.0, 41.5, -114.5, 42.0], ["us-id"]))
        r.resize(s, PACKS)
        self.assertEqual(s["regions"][1]["sizes"]["offroad"]["packs"], {"idaho": 100}, "the new rule: its state's pack, no neighbour's")

    def test_a_metro_area_across_a_state_line_gets_one_pack_for_each_state(self):
        s = shard(
            rec("us-id", "Idaho", "region", [-117.2, 42.0, -111.0, 49.0]),
            rec("us-nv", "Nevada", "region", [-120.0, 35.0, -114.0, 42.0]),
            rec("us-metro-twin", "Twin", "metro", [-115.2, 41.8, -114.8, 42.2], ["us-id", "us-nv"]),
        )
        r.resize(s, PACKS)
        self.assertEqual(s["regions"][2]["sizes"]["offroad"]["packs"], {"idaho": 100, "nevada": 200})

    def test_no_state_the_deepest_inside_box_wins_and_a_region_no_box_holds_gets_every_pack_that_reaches_it(self):
        drawn = rec("drawn", "Drawn", "locality", [-116.0, 40.0, -115.0, 41.5])  # no parents, no state
        both = rec("wide", "Wide", "multi_state", [-119.0, 40.0, -112.0, 45.0])  # no box holds it
        s = shard(drawn, both)
        r.resize(s, PACKS)
        self.assertEqual(s["regions"][0]["sizes"]["offroad"]["packs"], {"nevada": 200}, "only Nevada's box holds it")
        self.assertEqual(s["regions"][1]["sizes"]["offroad"]["packs"], {"idaho": 100, "nevada": 200})

    def test_a_region_with_no_off_road_part_stays_without_and_terrain_and_the_rest_are_untouched(self):
        a = rec("a", "A", "county", [10.0, 10.0, 11.0, 11.0])
        del a["sizes"]["offroad"]
        b = rec("us-id-y", "Y", "county", [-115.0, 44.0, -114.0, 45.0], ["us-id"])
        s = shard(rec("us-id", "Idaho", "region", [-117.2, 42.0, -111.0, 49.0]), a, b)
        r.resize(s, PACKS)
        self.assertNotIn("offroad", s["regions"][1]["sizes"])
        self.assertEqual(s["regions"][2]["sizes"]["offroad"]["terrain"], 7)

    def test_the_antimeridian_box_reaches_a_pack_on_either_side(self):
        alaska = rec("us-ak", "Alaska", "region", [172.0, 51.0, -129.0, 71.0])
        far = pack("british-columbia", "British Columbia", "CA", [-139.8, 47.8, -113.3, 60.5], 300)
        s = shard(alaska)
        r.resize(s, [far])
        self.assertEqual(s["regions"][0]["sizes"]["offroad"]["packs"], {"british-columbia": 300})

    def test_the_shard_goes_back_out_as_it_came(self):
        raw = json.dumps(shard(rec("us-id", "Idaho", "region", [-117.2, 42.0, -111.0, 49.0])), separators=(",", ":"), ensure_ascii=False).encode()
        self.assertEqual(r.dump(json.loads(raw)), raw)


if __name__ == "__main__":
    unittest.main()
