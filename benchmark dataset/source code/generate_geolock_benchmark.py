#!/usr/bin/env python3
"""Generate reusable GeoLock Hub benchmark data, NOT experiment executions.

Public inputs: OpenDOSM district population, user-supplied NGO public-reference CSV,
Geofabrik OSM PBF. Outputs: geographic context, synthetic entities, scenario membership,
policy-generated labels and frozen directed road distances. No model fitting, E1-E4
condition outcomes, claim execution, generated pickup tasks or train/test split.

The NGO-centred operational sample falls inside Peninsular Malaysia, but does
NOT cover its entire geography. District sampling labels are EXPLICIT locality
proxies, not official mapped district boundaries. See generation_manifest.json.
"""
import argparse
import collections
import csv
import datetime as dt
import hashlib
import json
import math
from pathlib import Path
import random

import numpy as np
from scipy.sparse import csr_matrix
from scipy.sparse.csgraph import dijkstra, connected_components
from scipy.spatial import cKDTree


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
INPUTS = ROOT / 'dataset'
OUTPUT = HERE.parent / 'dataset'
CACHE = HERE.parent / 'road cache'
VERSION = 'GEOLOCK-BM-v3.1-NGO11-FIXED'
MATRIX = 'OSM-DIRECTED-v3.0-NGO-REGIONS'
SEED = 20260915
HUB_SHORTLIST_SIZE = 8
ROUTE_SELECTION_SEED_OFFSET = 81029
LEASE_SELECTION_SEED_OFFSET = 81028
CATEGORIES = ('clothing', 'books', 'electronics', 'food', 'appliances', 'furniture')
HANDLING = {'clothing':.10,'books':.20,'electronics':.40,'food':.60,'appliances':.80,'furniture':1.00}
# Synthetic category-aware quantity envelopes reduce implausible 0.5 kg furniture.
CATEGORY_WEIGHT = {
 'clothing':(.5,.86),'books':(.5,.82),'electronics':(.8,.76),
 'food':(.5,.82),'appliances':(3.0,.55),'furniture':(7.0,.33)
}

# Extraction/catchment regions are generated from the supplied 11 NGO references.
# These are NOT official administrative polygons and NOT experiment geofences.
OPERATING_BOXES = []

def in_operating_area(lat, lon):
    return any(s <= lat <= n and w <= lon <= e for s,n,w,e in OPERATING_BOXES)

# NGO-centred locality proxies are only a population-weighted spatial sampling frame.
# District labels are public demographic context, not verified point-in-polygon results.
NGO_DISTRICTS = {
 'NGO001':('W.P. Kuala Lumpur','W.P. Kuala Lumpur'),
 'NGO002':('W.P. Kuala Lumpur','W.P. Kuala Lumpur'),
 'NGO003':('Johor','Johor Bahru'),
 'NGO004':('Selangor','Petaling'),
 'NGO005':('Pulau Pinang','Timur Laut'),
 'NGO006':('Perak','Kinta'),
 'NGO007':('Terengganu','Kemaman'),
 'NGO008':('W.P. Kuala Lumpur','W.P. Kuala Lumpur'),
 'NGO09':('Negeri Sembilan','Seremban'),
 'NGO010':('Pahang','Kuantan'),
 'NGO011':('Kedah','Kuala Muda'),
}

# Optional extra settlement proxies; location is used only as a sampling centre.
ADDITIONAL_LOCALITIES = [
 ('Petaling Jaya','Petaling','Selangor',3.105,101.628),
 ('Subang Jaya','Petaling','Selangor',3.067,101.598),
 ('Puchong','Petaling','Selangor',3.026,101.619),
 ('Kajang','Ulu Langat','Selangor',2.990,101.786),
 ('Cyberjaya','Sepang','Selangor',2.918,101.656),
 ('Putrajaya','W.P. Putrajaya','W.P. Putrajaya',2.927,101.693),
 ('Batu Caves','Gombak','Selangor',3.238,101.685),
 ('Skudai','Johor Bahru','Johor',1.535,103.666),
 ('Tebrau','Johor Bahru','Johor',1.558,103.788),
 ('Permas Jaya','Johor Bahru','Johor',1.496,103.834),
 ('Senawang','Seremban','Negeri Sembilan',2.690,101.985),
 ('Ipoh','Kinta','Perak',4.590,101.090),
 ('Georgetown','Timur Laut','Pulau Pinang',5.420,100.330),
 ('Kuantan','Kuantan','Pahang',3.815,103.325),
]


def rows(path):
    with open(path,encoding='utf-8-sig',newline='') as f:
        yield from csv.DictReader(f)


def write_csv(out,name,data):
    if not data: raise RuntimeError('No records for '+name)
    with (out/(name+'.csv')).open('w',newline='',encoding='utf-8') as f:
        writer=csv.DictWriter(f,fieldnames=list(data[0]),extrasaction='ignore')
        writer.writeheader();writer.writerows(data)


def sha(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for block in iter(lambda:f.read(4*1024*1024),b''):h.update(block)
    return h.hexdigest()


def distance_km(lat,lon,lat2,lon2):
    dy=math.radians(lat2-lat);dx=math.radians(lon2-lon)
    a=math.sin(dy/2)**2+math.cos(math.radians(lat))*math.cos(math.radians(lat2))*math.sin(dx/2)**2
    return 12742*math.asin(min(1,math.sqrt(a)))


def operating_overlap(start,end,opening,closing):
    start,end=dt.datetime.fromisoformat(start),dt.datetime.fromisoformat(end)
    day=start.date()
    while day<=end.date():
        lo=dt.datetime.combine(day,dt.time.fromisoformat(opening))
        hi=dt.datetime.combine(day,dt.time.fromisoformat(closing))
        if max(start,lo)<min(end,hi):return True
        day+=dt.timedelta(days=1)
    return False


def geohash(lat,lon,precision=5):
    alphabet='0123456789bcdefghjkmnpqrstuvwxyz'
    bounds=[[-90,90],[-180,180]];value=0;bit=0;answer=''
    while len(answer)<precision:
        axis=1 if bit%2==0 else 0
        mid=sum(bounds[axis])/2
        high=(lon if axis else lat)>=mid
        if high:bounds[axis][0]=mid
        else:bounds[axis][1]=mid
        value=(value<<1)|int(high);bit+=1
        if bit%5==0:answer+=alphabet[value];value=0
    return answer



def choose_lease_inputs(agents, listings, ngo_lookup, expired_count, active_count, seed):
    """Return independent replay inputs, each with a distinct eligible alternative.

    The generator establishes feasible initial participants, but never executes
    a claim/reclaim transaction or encodes an expected claim result.
    """
    eligible = []
    for li in sorted(listings, key=lambda row: row['listing_id']):
        participants = [ag for ag in agents
                        if ngo_lookup[(ag['ngo_agent_id'], li['listing_id'])][0] is not None
                        and ngo_lookup[(ag['ngo_agent_id'], li['listing_id'])][0] <= 20]
        if len(participants) >= 2:
            eligible.append((li, participants))
    random.Random(seed + LEASE_SELECTION_SEED_OFFSET).shuffle(eligible)
    if len(eligible) < expired_count + active_count:
        raise ValueError(f'Need {expired_count + active_count} distinct two-NGO lease listings; '
                         f'only {len(eligible)} are available')
    expired, active = [], []
    for j, (li, participants) in enumerate(eligible[:expired_count + active_count]):
        prior = participants[j % len(participants)]
        replacement = participants[(j+1) % len(participants)]
        assert prior['ngo_agent_id'] != replacement['ngo_agent_id']
        (expired if j < expired_count else active).append((li, prior, replacement))
    return expired, active

def choose_route_plans(agents, listings, vehicles, ngo_lookup, count, seed):
    """Choose matched E4 input sets, without running claim/route baselines.

    Replaying separately remains mandatory; unique listing membership prevents
    artificial overlap between distinct route scenario experimental units.
    """
    rng = random.Random(seed + ROUTE_SELECTION_SEED_OFFSET)
    eligible_by_agent = {
        ag['ngo_agent_id']: sorted(
            [li for li in listings
             if ngo_lookup[(ag['ngo_agent_id'], li['listing_id'])][0] is not None
             and ngo_lookup[(ag['ngo_agent_id'], li['listing_id'])][0] <= 15],
            key=lambda li: li['listing_id'])
        for ag in agents
    }
    available_agents = [ag for ag in agents
                        if len(eligible_by_agent[ag['ngo_agent_id']]) >= 5]
    if not available_agents:
        raise ValueError('No NGO with at least five eligible route-listing inputs')
    used_listing_ids = set()
    plans = []
    cursor = 0

    def has_common_collection_window(group):
        start = max(dt.datetime.fromisoformat(li['created_at']) for li in group)
        end = min(dt.datetime.fromisoformat(li['listing_expires_at']) for li in group)
        return start < end

    for i in range(count):
        profile = ('NORMAL', 'CAPACITY_PRESSURE', 'GEOGRAPHIC_SPREAD', 'CONNECTIVITY_STRESS')[i % 4]
        selected = None
        for delta in range(len(available_agents)):
            ai = (cursor + delta) % len(available_agents)
            agent = available_agents[ai]
            aid = agent['ngo_agent_id']
            unused = [li for li in eligible_by_agent[aid]
                      if li['listing_id'] not in used_listing_ids]
            if len(unused) < 5:
                continue
            if profile == 'CAPACITY_PRESSURE':
                pool = [li for li in unused if float(li['listing_weight_kg']) >= 22]
            elif profile == 'GEOGRAPHIC_SPREAD':
                distant = sorted(unused, key=lambda li:
                    (-ngo_lookup[(aid, li['listing_id'])][0], li['listing_id']))
                pool = distant[:max(5, len(distant) // 3)]
            else:
                pool = unused
            if len(pool) < 5:
                continue
            for _ in range(80):
                group = rng.sample(pool, 5)
                if has_common_collection_window(group):
                    selected = (agent, profile, group, ai)
                    break
            if selected is not None:
                break
        if selected is None:
            raise ValueError(f'Only {len(plans)} of {count} non-overlapping route scenarios '
                             f'could be formed at profile {profile}; enlarge validated study inputs')
        ag, profile, group, ai = selected
        cursor = (ai + 1) % len(available_agents)
        used_listing_ids.update(li['listing_id'] for li in group)
        fleet = [v for v in vehicles if v['ngo_agent_id'] == ag['ngo_agent_id']]
        if profile == 'CAPACITY_PRESSURE':
            fleet = [v for v in fleet if v['vehicle_type'] == 'small_car']
        elif profile == 'GEOGRAPHIC_SPREAD':
            fleet = [v for v in fleet if v['vehicle_type'] == 'van']
        if not fleet:
            raise ValueError('No corresponding fleet for route profile')
        plans.append((ag, profile, group, fleet))
    if len(used_listing_ids) != 5 * count:
        raise AssertionError('Route listing reused between independent scenario records')
    return plans

def population_context(path):
    data={}
    for r in rows(path):
        if (r['date'],r['sex'],r['age'],r['ethnicity'])==('2025-01-01','both','overall','overall'):
            data[(r['state'],r['district'])]=int(round(1000*float(r['population'])))
    if not data: raise ValueError('Missing 2025 both/overall/overall population slice')
    if any((st,di) not in data for _,di,st,*_ in ADDITIONAL_LOCALITIES):
        raise ValueError('A named locality proxy lacks an OpenDOSM district population')
    return data


def load_network(nodes,edges):
    raw=np.loadtxt(edges,delimiter=',',dtype=np.float64,ndmin=2)
    u=raw[:,0].astype('int64');v=raw[:,1].astype('int64')
    nraw=np.loadtxt(nodes,delimiter=',',dtype=np.float64,ndmin=2)
    allowed=np.zeros(len(nraw),dtype=bool)
    for s,n,w,e in OPERATING_BOXES:
        allowed |= (nraw[:,1]>=s)&(nraw[:,1]<=n)&(nraw[:,2]>=w)&(nraw[:,2]<=e)
    allowed_ids=nraw[allowed,0].astype('int64')
    keep=np.isin(u,allowed_ids)&np.isin(v,allowed_ids)
    raw=raw[keep];u=u[keep];v=v[keep]
    ids=np.unique(np.concatenate((u,v)))
    iu=np.searchsorted(ids,u);iv=np.searchsorted(ids,v)
    order=np.lexsort((iv,iu));iu=iu[order];iv=iv[order];ww=raw[order,2];tt=raw[order,3]
    starts=np.r_[0,np.flatnonzero((iu[1:]!=iu[:-1])|(iv[1:]!=iv[:-1]))+1]
    ends=np.r_[starts[1:],len(order)]
    # Parallel OSM ways can share an ordered node pair; take the shortest,
    # NEVER sum duplicate edge lengths (scipy COO conversion would sum them).
    weights=np.minimum.reduceat(ww,starts)
    times=np.asarray([tt[k+int(np.argmin(ww[k:e]))] for k,e in zip(starts,ends)])
    mat=csr_matrix((weights,(iu[starts],iv[starts])),shape=(len(ids),len(ids)))
    tmat=csr_matrix((times,(iu[starts],iv[starts])),shape=(len(ids),len(ids)))
    no=np.argsort(nraw[:,0].astype('int64'))
    old=nraw[no,0].astype('int64');index=np.searchsorted(old,ids)
    if not np.array_equal(old[index],ids):raise RuntimeError('Edges refer to missing road node coordinates')
    coord=nraw[no[index],1:3]
    # Weak components filter obvious isolated road stubs; matrix retains
    # directed reachability and never treats weak connection as a valid route.
    _,labels=connected_components(mat,directed=True,connection='weak')
    counts=np.bincount(labels);mask=counts[labels]>=300
    eligible=np.flatnonzero(mask)
    xy=np.column_stack((coord[eligible,0]*111.195,coord[eligible,1]*111.195*math.cos(math.radians(4))))
    tree=cKDTree(xy)
    return dict(ids=ids,coord=coord,mat=mat,time=tmat,rev=mat.T.tocsr(),eligible=eligible,tree=tree,labels=labels)


def road_snap(g,lat,lon,max_metres=500):
    dd,j=g['tree'].query([lat*111.195,lon*111.195*math.cos(math.radians(4))])
    ix=int(g['eligible'][j])
    true_dist=1000*distance_km(lat,lon,*g['coord'][ix])
    if true_dist>max_metres:return None
    return ix,round(true_dist,1)


def main(a):
    out=Path(a.output);out.mkdir(parents=True,exist_ok=True)
    randomiser=random.Random(a.seed)
    pop=population_context(a.population)
    ngos=list(rows(a.ngos))
    for r in ngos:
        if r['ngo_id'] not in NGO_DISTRICTS:
            raise ValueError(f"Add an explicit population-district sampling proxy for updated NGO {r['ngo_id']}")
    global OPERATING_BOXES
    OPERATING_BOXES = []
    for r in ngos:
        lat,lon=float(r['latitude']),float(r['longitude'])
        m=17/111.2; n=17/(111.2*math.cos(math.radians(lat)))
        OPERATING_BOXES.append((lat-m,lat+m,lon-n,lon+n))
    # The nearest proxy provides an *approximate* district assignment only;
    # we never describe it as an OSM or government-verified polygon.
    locality_anchors=[(r['ngo_name'], NGO_DISTRICTS[r['ngo_id']][1],
          NGO_DISTRICTS[r['ngo_id']][0],float(r['latitude']),float(r['longitude'])) for r in ngos]
    locality_anchors+=ADDITIONAL_LOCALITIES
    def administrative(lat,lon):
        name,di,st,_,_=min(locality_anchors,key=lambda a:distance_km(lat,lon,a[3],a[4]))
        return st,di
    if not ngos:raise ValueError('No NGO public references available')
    if len(set(r['ngo_id'] for r in ngos))!=len(ngos):raise ValueError('Duplicate NGO reference IDs')
    for r in ngos:
        if not all(r.get(k) for k in ['ngo_id','ngo_name','state','latitude','longitude','status']):
            raise ValueError('NGO public reference missing mandatory field')
        if str(r['status']).upper() not in ('AKTIF','ACTIVE','VERIFIED'):
            raise ValueError('Non-active source NGO row is not admitted: '+r['ngo_id'])
    g=load_network(a.nodes,a.edges)
    # Add only OSM amenity-derived candidate hubs, no invented official facilities.
    raw_sites=list(rows(a.osm_hubs))
    sites=[];used_osm=set();bad_site_count=0
    for r in raw_sites:
        key=(r['osm_type'],r['osm_id'])
        if key in used_osm:continue
        used_osm.add(key)
        lat,lon=float(r['latitude']),float(r['longitude'])
        if not in_operating_area(lat,lon):continue
        admin=administrative(lat,lon)
        if admin is None or admin[1] is None:continue
        snap=road_snap(g,lat,lon)
        if snap is None:bad_site_count+=1;continue
        if min(distance_km(lat,lon,float(n['latitude']),float(n['longitude'])) for n in ngos)>28:continue
        sites.append((r,lat,lon,snap))
    sites.sort(key=lambda s:(s[0]['osm_type'],int(s[0]['osm_id'])))
    # Keep the available OSM candidates balanced across the updated NGO regions.
    region_sites=collections.defaultdict(list)
    for site in sites:
        r,lat,lon,_=site
        nearest=min(ngos,key=lambda n:distance_km(lat,lon,float(n['latitude']),float(n['longitude'])))
        region_sites[nearest['ngo_id']].append(site)
    sites=[]
    for region in sorted(region_sites):
        choices=region_sites[region]
        random.Random(a.seed+sum(ord(c) for c in region)).shuffle(choices)
        sites+=choices[:18]
    sites.sort(key=lambda s:(s[0]['osm_type'],int(s[0]['osm_id'])))
    if len(sites)<4:raise ValueError(f'Only {len(sites)} usable OSM amenity hubs; no synthetic fallback allowed')
    print('Loaded',len(g['ids']),'road nodes and',len(sites),'OSM hub candidates',flush=True)
    tables=collections.OrderedDict()
    locs=[];locations={};hubs=[];agents=[];vehicles=[];refs=[];donors=[];donations=[]
    def place(tag,lat,lon,state,district,origin,name='',snap_override=None):
        admin=(state,district) if tag=='NGO' else administrative(lat,lon)
        if not admin or not admin[1]:raise RuntimeError('Missing declared district sampling proxy')
        state,district=admin
        snap=snap_override if snap_override is not None else road_snap(g,lat,lon)
        ix=snap[0] if snap else None
        item=dict(location_id=f'LOC{len(locs)+1:07d}',location_type=tag,state=state,district=district,
                  latitude=round(lat,7),longitude=round(lon,7),road_node_id=str(g['ids'][ix]) if ix is not None else '',
                  route_available_flag=int(ix is not None),node_snap_distance_m=snap[1] if snap else '',
                  coordinate_origin='SYNTHETIC' if origin.startswith('SYNTHETIC') else 'PUBLIC',
                  coordinate_source_detail=origin,locality=name,
                  administrative_assignment='NEAREST_DECLARED_LOCALITY_PROXY',
                  operational_region=min(ngos,key=lambda n:distance_km(lat,lon,float(n['latitude']),float(n['longitude'])))['ngo_id'])
        locs.append(item);locations[item['location_id']]=item
        return item,ix
    for r in ngos:
        lat,lon=float(r['latitude']),float(r['longitude'])
        normalized_state={'Kuala Lumpur':'W.P. Kuala Lumpur','Putrajaya':'W.P. Putrajaya'}.get(r['state'],r['state'])
        li,idx=place('NGO',lat,lon,NGO_DISTRICTS[r['ngo_id']][0],NGO_DISTRICTS[r['ngo_id']][1],'PUBLIC_NGO_REFERENCE',r['ngo_name'])
        if idx is None:raise RuntimeError('NGO outside 500m road snapping: '+r['ngo_id'])
        refs.append(dict(public_ref_key=r['ngo_id'],organisation_name=r['ngo_name'],state=li['state'],source_state=r['state'],
            latitude=lat,longitude=lon,category=r.get('category',''),status=r['status'],
            source_platform='USER_UPLOADED_REFERENCE',coordinate_source='USER_UPLOADED_REFERENCE',
            registry_verification='NOT_INDEPENDENTLY_VERIFIED',
            address=r.get('address',''),phone=r.get('phone',''),email=r.get('email',''),website=r.get('website',''),
            subcategory=r.get('subcategory',''),source_record_id=r['ngo_id'],source_record_type='USER_SUPPLIED_CSV_ROW',
            source_url=r.get('source_url',''),source_reference='dataset/NGO_references.csv#'+r['ngo_id'],
            retrieved_date=r.get('retrieved_date',''),verification_level='SUPPLIED_ONLY'))
        agent_id='AGENT-'+r['ngo_id']
        agents.append(dict(ngo_agent_id=agent_id,public_ref_key=r['ngo_id'],location_id=li['location_id'],
            road_node_id=li['road_node_id'],active_flag=1,capability_profile='GENERAL_NONHAZARDOUS_SYNTHETIC',
            location_freshness_flag=0,location_freshness_status='NOT_INDEPENDENTLY_VERIFIED',
            benchmark_location_valid_flag=1))
        for k,(type_,capacity) in enumerate((('small_car',100),('van',500)),1):
            vehicles.append(dict(vehicle_id=f'VEH-{r["ngo_id"]}-{k}',ngo_agent_id=agent_id,
              vehicle_type=type_,vehicle_capacity_kg=capacity,depot_road_node_id=li['road_node_id'],
              active_flag=1))
    hub_idx={};hub_by={}
    for r,lat,lon,snap in sites:
        # The locality district assignment is a declared sampling proxy, not a polygon.
        nearest=min(ngos,key=lambda n:distance_km(lat,lon,float(n['latitude']),float(n['longitude'])))
        li,idx=place('HUB',lat,lon,'','','PUBLIC_OSM_AMENITY',r.get('name',''),snap)
        accepted=sorted(randomiser.sample(CATEGORIES,k=randomiser.choice((5,6))))
        cap=randomiser.randint(50,250)
        stored=round(cap*randomiser.uniform(0,.8),2)
        reserve=round(min(cap-stored,cap*randomiser.uniform(0,.2)),2)
        h=dict(hub_id=f'HUB{len(hubs)+1:04d}',location_id=li['location_id'],osm_type=r['osm_type'],
           osm_id=r['osm_id'],osm_amenity=r['amenity'],osm_name=r.get('name',''),
           hub_capacity_kg=cap,hub_load_kg=stored,hub_reserved_kg=reserve,
           remaining_capacity_kg=round(cap-stored-reserve,2),hub_active_flag=int(randomiser.random()>.05),
           operating_start='09:00',operating_end='18:00',accepted_categories='|'.join(accepted),
           facility_approval='NOT_VERIFIED_DONATION_CENTRE')
        hubs.append(h);hub_idx[h['hub_id']]=idx;hub_by[h['hub_id']]=h
    # Population-weighted sampling of locality proxy anchors, but only where
    # supplied NGO context supports a catchment. Cyberjaya is kept as a small
    # explicit potentially-ineligible scenario stratum, NOT assumed eligible.
    selected_localities=[]
    for name,di,st,lat,lon in locality_anchors:
        if (st,di) not in pop: continue
        if in_operating_area(lat,lon) and min(distance_km(lat,lon,float(n['latitude']),float(n['longitude'])) for n in ngos)<=30:
            selected_localities.append((name,di,st,lat,lon))
    bydistrict=collections.Counter((st,di) for _,di,st,*_ in selected_localities)
    ldata=[]
    for name,di,st,lat,lon in selected_localities:
        nearest=min(distance_km(lat,lon,float(n['latitude']),float(n['longitude'])) for n in ngos)
        if nearest>30 or not in_operating_area(lat,lon):continue
        exposure=math.exp(-max(nearest-5,0)/19)
        weight=pop[(st,di)]/bydistrict[(st,di)]*exposure
        ldata.append(dict(locality_id=f'AREA{len(ldata)+1:03d}',locality=name,state=st,district=di,
                    anchor_latitude=lat,anchor_longitude=lon,district_population_persons=pop[(st,di)],
                    synthetic_proximity_factor=round(exposure,6),sampling_weight=weight))
    weights=np.array([x['sampling_weight'] for x in ldata],dtype=float)
    expected=weights/weights.sum()*a.donations
    quotas=np.floor(expected).astype(int)
    for k in np.argsort(-(expected-quotas))[:a.donations-int(quotas.sum())]:quotas[k]+=1
    # Use real OSM routable road vertices around a locality rather than placing
    # synthetic households at real addresses or inventing unmapped coordinates.
    cos4=math.cos(math.radians(4))
    anchor_xy=np.array([[r[3]*111.195,r[4]*111.195*cos4] for r in locality_anchors])
    ngo_xy=np.array([[float(r['latitude'])*111.195,float(r['longitude'])*111.195*cos4] for r in ngos])
    used_donor_nodes=set()
    for area,n in zip(ldata,quotas):
        area['sample_count']=int(n)
        center=np.array([area['anchor_latitude']*111.195,area['anchor_longitude']*111.195*cos4])
        rawpool=np.asarray(g['tree'].query_ball_point(center,r=5.5),dtype=np.int64)
        indices=g['eligible'][rawpool]
        xy=np.column_stack((g['coord'][indices,0]*111.195,g['coord'][indices,1]*111.195*cos4))
        closest=np.argmin(((xy[:,None,:]-anchor_xy[None,:,:])**2).sum(axis=2),axis=1)
        good_area=np.asarray([(locality_anchors[k][2],locality_anchors[k][1])==(area['state'],area['district']) for k in closest])
        near_ngo=np.sqrt(((xy[:,None,:]-ngo_xy[None,:,:])**2).sum(axis=2).min(axis=1))<=25
        pool=[int(ix) for ix in indices[good_area & near_ngo] if int(ix) not in used_donor_nodes]
        if len(pool)<max(20,int(n)):
            raise RuntimeError(f"Not enough geographically assigned road nodes in locality {area['locality']}: {len(pool)} for {int(n)} donations")
        randomiser.shuffle(pool)
        for idx in pool[:int(n)]:
            # Never duplicate a synthetic donor's road vertex anywhere in dataset.
            used_donor_nodes.add(idx)
            lat,lon=map(float,g['coord'][idx])
            li,_=place('DONOR',lat,lon,area['state'],area['district'],'SYNTHETIC_SELECTION_OF_OSM_ROAD_NODE',area['locality'],(idx,0))
            did=f'DON{len(donations)+1:06d}'
            donor_id=f'DNR{len(donors)+1:06d}'
            donors.append(dict(donor_id=donor_id,location_id=li['location_id'],state=area['state'],district=area['district']))
            category=randomiser.choice(CATEGORIES)
            minweight, small_fraction=CATEGORY_WEIGHT[category]
            small=randomiser.random()<small_fraction
            wt=round(randomiser.uniform(minweight,9.8) if small else randomiser.uniform(10,30),2)
            i=len(donations)
            if i%333==0:wt=9.9
            elif i%337==0:wt=10.0
            elif i%339==0:wt=10.1
            start=dt.datetime(2026,11,2,9)+dt.timedelta(minutes=15*randomiser.randint(0,20))
            finish=start+dt.timedelta(hours=randomiser.randint(8,72))
            donations.append(dict(donation_id=did,donor_id=donor_id,category=category,
                weight_kg=wt,received_at=(start-dt.timedelta(minutes=randomiser.randint(30,180))).isoformat(timespec='minutes'),availability_start=start.isoformat(timespec='minutes'),
                availability_end=finish.isoformat(timespec='minutes'),
                collection_path='COMMUNITY_HUB' if wt<10 else 'DIRECT_HOUSEHOLD',
                valid_input_flag=1,classification_reason='BELOW_THRESHOLD' if wt<10 else 'AT_OR_ABOVE_THRESHOLD',
                geographic_group_id=geohash(lat,lon)))
    # Include genuine closed-hours candidate tests by modifying a few existing
    # 8-hour availability windows, rather than duplicating donor records.
    for d in [d for d in donations if d['collection_path']=='COMMUNITY_HUB'][:8]:
        d['availability_start']='2026-11-02T19:00'
        d['availability_end']='2026-11-03T03:00'
    donor_lookup={n['donor_id']:n for n in donors}
    donor_loc={d['donation_id']:locations[donor_lookup[d['donor_id']]['location_id']] for d in donations}
    roadids={str(n):i for i,n in enumerate(g['ids'])}
    matrix={}
    def save_matrix(fromnode,tonode,km,mins):
        key=(str(fromnode),str(tonode))
        if key not in matrix:
            matrix[key]=dict(matrix_id=MATRIX,from_node_id=key[0],to_node_id=key[1],
                             road_distance_km=round(km,5) if km is not None else '',
                             travel_time_min=round(mins,5) if mins is not None else '',
                             route_available_flag=int(km is not None))
    def calculate(source_ix,target_indices,reverse=False):
        graph=g['rev'] if reverse else g['mat']
        dd,pre=dijkstra(graph,directed=True,indices=source_ix,return_predecessors=True)
        # Memoise cumulative minutes on the SHORTEST-DISTANCE predecessor tree.
        # Without this, tracing thousands of shared road prefixes independently
        # turns matrix preparation into millions of slow Python sparse lookups.
        memo={source_ix:0.0}
        def mins_to(target):
            if target in memo:return memo[target]
            stack=[];node=target
            while node not in memo:
                p=int(pre[node])
                if p<0:return None
                stack.append((node,p));node=p
            while stack:
                node,p=stack.pop()
                value=float(g['time'][node,p] if reverse else g['time'][p,node])
                memo[node]=memo[p]+value
            return memo[target]
        ans={}
        for target in set(target_indices):
            if target is None or target<0:continue
            if not np.isfinite(dd[target]):ans[target]=(None,None);continue
            ans[target]=(float(dd[target]),mins_to(target))
        return ans
    def record_direct(fromix,toix,ans,reverse=False):
        km,mins=ans
        fromid=g['ids'][fromix];toid=g['ids'][toix]
        if reverse:fromid,toid=toid,fromid
        save_matrix(fromid,toid,km,mins)
        return km,mins
    # Build the complete benchmark donation-hub candidate groups from nearest
    # OSM amenity locations. Infeasible rows are retained; no learned rankings.
    candidates=[];feasible_by=collections.defaultdict(list)
    small=[d for d in donations if d['collection_path']=='COMMUNITY_HUB']
    smallidx={d['donation_id']:roadids[donor_loc[d['donation_id']]['road_node_id']] for d in small}
    nearest_hubs={}
    for d in small:
        loc=donor_loc[d['donation_id']]
        nearest_hubs[d['donation_id']]=sorted(hubs,key=lambda h:distance_km(float(loc['latitude']),float(loc['longitude']),
                float(locations[h['location_id']]['latitude']),float(locations[h['location_id']]['longitude'])))[:HUB_SHORTLIST_SIZE]
    grouped=collections.defaultdict(list)
    for d in small:
        for h in nearest_hubs[d['donation_id']]:grouped[h['hub_id']].append(d)
    for groupn,(hid,items) in enumerate(grouped.items(),1):
        if groupn % 10 == 0: print('hub shortest paths',groupn,'/',len(grouped),flush=True)
        h=hub_by[hid];hi=hub_idx[hid]
        ans=calculate(hi,[smallidx[d['donation_id']] for d in items],reverse=True)
        for d in items:
            ix=smallidx[d['donation_id']]
            km,mins=record_direct(hi,ix,ans[ix],reverse=True)
            weight=float(d['weight_kg']);available=float(h['remaining_capacity_kg'])
            compat=int(d['category'] in h['accepted_categories'].split('|'))
            capacity=int(weight<=available)
            operating=int(operating_overlap(d['availability_start'],d['availability_end'],h['operating_start'],h['operating_end']))
            active=int(h['hub_active_flag'])
            valid=int(compat and capacity and operating and active and km is not None)
            row=dict(donation_id=d['donation_id'],hub_id=hid,item_compatible_flag=compat,
                capacity_feasible_flag=capacity,operating_feasible_flag=operating,active_feasible_flag=active,
                route_available_flag=int(km is not None),feasible_flag=valid,
                road_distance_km=round(km,5) if km is not None else '',
                travel_time_min=round(mins,5) if mins is not None else '',
                donation_weight_kg=weight,
                utilisation_ratio=round(float(h['hub_load_kg'])/float(h['hub_capacity_kg']),6),
                remaining_capacity_kg=available,
                capacity_pressure=round(weight/available,6) if available else '',
                handling_penalty=HANDLING[d['category']],reference_score='',reference_rank='',
                geographic_group_id=d['geographic_group_id'])
            candidates.append(row)
            if valid:feasible_by[d['donation_id']].append(row)
    for did,group in feasible_by.items():
        values=[float(r['road_distance_km']) for r in group];lower=min(values);rng=max(values)-lower
        for r in group:
            norm=(float(r['road_distance_km'])-lower)/rng if rng else 0
            r['reference_score']=round(.45*norm+.20*r['utilisation_ratio']+.25*r['capacity_pressure']+.10*r['handling_penalty'],8)
        group.sort(key=lambda r:(r['reference_score'],float(r['road_distance_km']),r['hub_id']))
        for rank,r in enumerate(group,1):r['reference_rank']=rank
    # Claimable initial listings; benchmark NEVER creates committed ownership.
    listings=[]
    for d in donations:
        if d['collection_path']!='DIRECT_HOUSEHOLD':continue
        loc=donor_loc[d['donation_id']]
        listings.append(dict(listing_id=f'LST{len(listings)+1:06d}',source_type='DIRECT_DONATION',source_id=d['donation_id'],
           pickup_location_id=loc['location_id'],pickup_road_node_id=loc['road_node_id'],
           listing_weight_kg=d['weight_kg'],initial_state='AVAILABLE',created_at=d['availability_start'],
           listing_expires_at=d['availability_end'],listing_version=1))
    donor_by={d['donation_id']:d for d in donations};listing_by={r['listing_id']:r for r in listings}
    agent_ix={r['ngo_agent_id']:roadids[r['road_node_id']] for r in agents}
    # Freeze full origin-to-listing NGO distance pairs for neutral E2/E4 inputs.
    ngo_lookup={}
    ngo_donation_lookup={}
    ngo_hub_lookup={}
    for ag,gi in agent_ix.items():
        arr=calculate(gi,[roadids[donor_loc[d['donation_id']]['road_node_id']] for d in donations]+list(hub_idx.values()))
        for hid,ix in hub_idx.items():ngo_hub_lookup[(ag,hid)]=record_direct(gi,ix,arr[ix])
        for d in donations:
            ix=roadids[donor_loc[d['donation_id']]['road_node_id']]
            ngo_donation_lookup[(ag,d['donation_id'])]=record_direct(gi,ix,arr[ix])
        for li in listings:
            idx=roadids[li['pickup_road_node_id']]
            ngo_lookup[(ag,li['listing_id'])]=record_direct(gi,idx,arr[idx])
    scenarios=[];s_members=[];batch=[];batch_members=[];claim_states=[]
    def create(kind,n,note=''):
        sid=f'SCN-{kind}-{n:04d}'
        scenarios.append(dict(scenario_id=sid,scenario_type=kind,scenario_seed=a.seed+len(scenarios),
              matrix_id=MATRIX,scenario_version=VERSION,created_at='2026-11-01T00:00',
              scenario_design_note=note,scenario_profile='STANDARD'))
        return sid
    def member(sid,typ,id_,role):
        s_members.append(dict(scenario_id=sid,entity_type=typ,entity_id=id_,scenario_role=role))
    # No E1 train/test partition here; that belongs to baseline model evaluation.
    recommended=[d for d in small if len(feasible_by[d['donation_id']])>=2]
    randomiser.shuffle(recommended)
    if len(recommended)<a.recommendation_scenarios:
        raise ValueError(f'Insufficient complete feasible recommendation groups: {len(recommended)} vs {a.recommendation_scenarios}')
    for i,d in enumerate(recommended[:a.recommendation_scenarios],1):
        sid=create('HUB_RECOMMENDATION',i)
        member(sid,'DONATION',d['donation_id'],'SOURCE_DONATION')
        for c in nearest_hubs[d['donation_id']]:member(sid,'HUB',c['hub_id'],'CANDIDATE_HUB')
    edge=[d for d in small if not feasible_by[d['donation_id']]]
    if not edge:raise RuntimeError('Missing no-feasible-hub verification inputs')
    for i,d in enumerate(edge,1):
        sid=create('HUB_RECOMMENDATION_VERIFICATION',i,'no feasible hub; must return explicit no recommendation')
        scenarios[-1]['scenario_profile']='NO_FEASIBLE_HUB'
        member(sid,'DONATION',d['donation_id'],'SOURCE_DONATION')
        for h in nearest_hubs[d['donation_id']]:member(sid,'HUB',h['hub_id'],'CANDIDATE_HUB')
    # Benchmark claim scenarios are independent initial listing+agent states;
    # worker count and request timing belong solely to E2 experiment runner.
    # Generative NEARBY catchment sampling (15km) differs from E2's eventual
    # separately frozen eligibility radius (20km in the thesis). No benchmark
    # field labels agents as geofence-eligible; E2 rechecks directed distance.
    nearby_list=[]
    for li in listings:
        nearby=[ag for ag in agents if ngo_lookup[(ag['ngo_agent_id'],li['listing_id'])][0] is not None and
                ngo_lookup[(ag['ngo_agent_id'],li['listing_id'])][0]<=15]
        if nearby:nearby_list.append((li,nearby))
    if not nearby_list:raise RuntimeError('No geographically nearby claimable donation')
    randomiser.shuffle(nearby_list)
    contention=[]
    for li in listings:
        eligible=[ag for ag in agents if ngo_lookup[(ag['ngo_agent_id'],li['listing_id'])][0] is not None and ngo_lookup[(ag['ngo_agent_id'],li['listing_id'])][0]<=20]
        if len(eligible)>=2:contention.append((li,eligible))
    randomiser.shuffle(contention)
    if not contention:raise RuntimeError('No two-NGO contention scenario; check NGO cluster and donor catchments')
    for i in range(a.claim_scenarios):
        li,nearby=contention[i%len(contention)]
        sid=create('CLAIM_COORDINATION',i+1,'two or more eligible identities at 20km; 5/10 workers reuse identities; no claim outcome')
        member(sid,'LISTING',li['listing_id'],'CLAIMABLE_LISTING')
        for ag in nearby:
            member(sid,'NGO_AGENT',ag['ngo_agent_id'],'POTENTIAL_REQUESTER_UNASSESSED')
    for i,(li,nearby) in enumerate(nearby_list[:100],1):
        sid=create('GEOFENCE_VERIFICATION',i,'all supplied agents included; runner checks eligible and ineligible attempts')
        member(sid,'LISTING',li['listing_id'],'CLAIMABLE_LISTING')
        for ag in agents:member(sid,'NGO_AGENT',ag['ngo_agent_id'],'POTENTIAL_REQUESTER_UNASSESSED')
    # Independent expired and active replay fixtures have distinct eligible
    # alternative NGO identities but contain no precomputed claim outcome.
    expired_inputs, active_inputs = choose_lease_inputs(
        agents, listings, ngo_lookup, a.lease_scenarios, 25, a.seed)
    for i, (li, prior, replacement) in enumerate(expired_inputs, 1):
        sid = create('LEASE_RECOVERY', i,
                     'expired ownership; distinct geographically suitable replacement input; no outcome')
        member(sid, 'LISTING', li['listing_id'], 'CLAIMABLE_LISTING')
        member(sid, 'NGO_AGENT', prior['ngo_agent_id'], 'PRIOR_CLAIMANT')
        member(sid, 'NGO_AGENT', replacement['ngo_agent_id'], 'POTENTIAL_REPLACEMENT_CLAIMANT')
        claim_states.append(dict(
            scenario_id=sid, listing_id=li['listing_id'], ngo_agent_id=prior['ngo_agent_id'],
            input_state='EXPIRED',
            claim_expires_at=(dt.datetime.fromisoformat(li['created_at']) + dt.timedelta(hours=6)).isoformat(timespec='minutes'),
            replay_at=(dt.datetime.fromisoformat(li['created_at']) + dt.timedelta(hours=7)).isoformat(timespec='minutes'),
            handover_status='NOT_TRANSFERRED'))
    for i, (li, prior, replacement) in enumerate(active_inputs, 1):
        sid = create('LEASE_ACTIVE_VERIFICATION', i,
                     'active lease; distinct potential requester; no precomputed result')
        member(sid, 'LISTING', li['listing_id'], 'CLAIMABLE_LISTING')
        member(sid, 'NGO_AGENT', prior['ngo_agent_id'], 'PRIOR_CLAIMANT')
        member(sid, 'NGO_AGENT', replacement['ngo_agent_id'], 'POTENTIAL_REPLACEMENT_CLAIMANT')
        claim_states.append(dict(
            scenario_id=sid, listing_id=li['listing_id'], ngo_agent_id=prior['ngo_agent_id'],
            input_state='ACTIVE',
            claim_expires_at=(dt.datetime.fromisoformat(li['created_at']) + dt.timedelta(hours=6)).isoformat(timespec='minutes'),
            replay_at=(dt.datetime.fromisoformat(li['created_at']) + dt.timedelta(hours=2)).isoformat(timespec='minutes'),
            handover_status='NOT_TRANSFERRED'))
    # E3 reusable group templates: membership_state PROPOSED not ACTIVE, no
    # published batch/listing and NO precomputed hub/direct condition outcomes.
    byhubcat=collections.defaultdict(list)
    for d in small:
        if feasible_by[d['donation_id']]:
            h=feasible_by[d['donation_id']][0]['hub_id']
            byhubcat[(h,d['category'])].append(d)
    batches=[];used_d=set()
    for (hid,cat),items in sorted(byhubcat.items()):
        items=sorted(items,key=lambda d:(d['received_at'],d['donation_id']))
        ptr=0
        while ptr+3<=len(items):
            take=[];mass=0.
            for d in items[ptr:ptr+5]:
                if d['donation_id'] in used_d:continue
                if mass+float(d['weight_kg'])>30:break
                take.append(d);mass+=float(d['weight_kg'])
                if len(take)==5:break
            ptr+=max(1,len(take))
            if len(take)<3:continue
            if max(d['availability_start'] for d in take)>=min(d['availability_end'] for d in take):continue
            if mass>float(hub_by[hid]['remaining_capacity_kg']):continue
            compatible_agents=[ag for ag in agents if ngo_hub_lookup[(ag['ngo_agent_id'],hid)][0] is not None and ngo_hub_lookup[(ag['ngo_agent_id'],hid)][0]<=20 and all(ngo_donation_lookup[(ag['ngo_agent_id'],d['donation_id'])][0] is not None and ngo_donation_lookup[(ag['ngo_agent_id'],d['donation_id'])][0]<=20 for d in take)]
            if not compatible_agents:continue
            batches.append((hid,cat,take,round(mass,2)))
            for d in take:used_d.add(d['donation_id'])
    randomiser.shuffle(batches)
    if len(batches)<a.aggregation_scenarios:
        raise ValueError(f'Only {len(batches)} valid nonoverlapping aggregation templates; need {a.aggregation_scenarios}')
    for i,(hid,cat,group,mass) in enumerate(batches[:a.aggregation_scenarios],1):
        bid=f'BAT{i:06d}';sid=create('HUB_AGGREGATION',i,'same originals available to both later comparison conditions')
        hub=hub_by[hid];loc=locations[hub['location_id']]
        created=max(d['availability_start'] for d in group)
        batch.append(dict(batch_id=bid,hub_id=hid,batch_category=cat,batch_weight_kg=mass,
                 batch_item_count=len(group),pickup_location_id=loc['location_id'],pickup_road_node_id=loc['road_node_id'],
                 initial_state='CREATED',created_at=created,published_at='',batch_version=1,
                 ))
        member(sid,'HUB',hid,'CANDIDATE_AGGREGATION_SITE');member(sid,'HUB_BATCH',bid,'UNCOMMITTED_GROUP_TEMPLATE')
        compatible_agents=[ag for ag in agents if ngo_hub_lookup[(ag['ngo_agent_id'],hid)][0] is not None and ngo_hub_lookup[(ag['ngo_agent_id'],hid)][0]<=20 and all(ngo_donation_lookup[(ag['ngo_agent_id'],d['donation_id'])][0] is not None and ngo_donation_lookup[(ag['ngo_agent_id'],d['donation_id'])][0]<=20 for d in group)]
        bestngo=min(compatible_agents,key=lambda x:distance_km(float(loc['latitude']),float(loc['longitude']),
                                     float(locations[x['location_id']]['latitude']),float(locations[x['location_id']]['longitude'])))
        member(sid,'NGO_AGENT',bestngo['ngo_agent_id'],'SAME_COMPARISON_NGO')
        for v in vehicles:
            if v['ngo_agent_id']==bestngo['ngo_agent_id']:member(sid,'VEHICLE',v['vehicle_id'],'SAME_COMPARISON_FLEET')
        for d in group:
            batch_members.append(dict(batch_id=bid,donation_id=d['donation_id'],added_at=created,membership_state='PROPOSED'))
            member(sid,'DONATION',d['donation_id'],'ORIGINAL_DONATION')
        selected=[agent_ix[bestngo['ngo_agent_id']],hub_idx[hid]]+[roadids[donor_loc[d['donation_id']]['road_node_id']] for d in group]
        for source in sorted(set(selected)):
            ans=calculate(source,selected)
            for target in set(selected):record_direct(source,target,ans[target])
    # E4: neutral scenario listing/fleet inputs. E4 implementation MUST execute
    # protected claim and create its own valid confirmed tasks and immutable snapshots.
    route_plans = choose_route_plans(
        agents, listings, vehicles, ngo_lookup, a.route_scenarios, a.seed)
    for i, (ag, profile, group, chosen_fleet) in enumerate(route_plans, 1):
        if i % 10 == 1:
            print('route scenario distance matrix', i, '/', a.route_scenarios, flush=True)
        sid = create('ROUTE_PLANNING', i,
                     'unique unclaimed listing inputs; baseline creates claims and confirmed tasks')
        scenarios[-1]['scenario_profile'] = profile
        member(sid, 'NGO_AGENT', ag['ngo_agent_id'], 'INTENDED_CLAIMANT')
        for v in chosen_fleet:
            member(sid, 'VEHICLE', v['vehicle_id'], 'AVAILABLE_FLEET')
        selected = [agent_ix[ag['ngo_agent_id']]] + [roadids[x['pickup_road_node_id']] for x in group]
        for li in group:
            member(sid, 'LISTING', li['listing_id'], 'INITIAL_AVAILABLE_LISTING')
        for source in sorted(set(selected)):
            a_map = calculate(source, selected)
            for target in set(selected):
                record_direct(source, target, a_map[target])
    verification=[dict(case_id=f'WT-{i+1:02d}',weight_kg=w if w is not None else '',
       input_valid=int(w is not None and w>0),case_type='CLASSIFICATION_BOUNDARY',
       note='input state only; required outcome determined in RO1 implementation')
       for i,w in enumerate((None,-1,0,.5,9.9,10,10.1,30))]
    # Export the referenced road node coordinates as a compact, self-contained
    # counterpart to the (larger) extraction cache, as required by Appendix A.1.
    used_node_ids=set(str(x['road_node_id']) for x in locs if x['road_node_id'])
    for src,dst in matrix:
        used_node_ids.add(str(src));used_node_ids.add(str(dst))
    road_nodes=[]
    for node_id in sorted(used_node_ids,key=int):
        ix=roadids[node_id]
        lat,lon=map(float,g['coord'][ix])
        st,di=administrative(lat,lon)
        road_nodes.append(dict(road_node_id=node_id,latitude=round(lat,8),longitude=round(lon,8),
          state=st,district_key=di.casefold().replace(' ','_'),network_snapshot_id=MATRIX))
    used_pop=sorted(set((x['state'],x['district']) for x in ldata))
    tables.update(road_nodes=road_nodes,population_context=[dict(state=st,district=di,population_persons=pop[(st,di)],
           reference_date='2025-01-01',source_units='THOUSAND_PERSONS_MULTIPLIED_1000',
           state_key=st.casefold().replace(' ','_'),district_key=di.casefold().replace(' ','_'),
           population_weight=pop[(st,di)]/sum(pop[k] for k in used_pop)) for st,di in used_pop],
        locality_sampling=ldata,ngo_references=refs,locations=locs,donors=donors,donations=donations,
        hubs=hubs,ngo_agents=agents,vehicles=vehicles,donation_hub_candidates=candidates,
        hub_batches=batch,hub_batch_members=batch_members,listings=listings,
        scenarios=scenarios,scenario_members=s_members,claim_initial_states=claim_states,
        road_distance_matrix=list(matrix.values()),verification_cases=verification)
    # Validation is a benchmark-generation assertion, not a baseline result.
    donation_map={d['donation_id']:d for d in donations}
    location_ids={v['location_id'] for v in locs}
    hub_ids={h['hub_id'] for h in hubs}
    for h in hubs:
        assert 0 <= float(h['hub_load_kg'])+float(h['hub_reserved_kg']) <= float(h['hub_capacity_kg'])+1e-6
        assert float(h['remaining_capacity_kg']) >= -1e-6
    assert all(r['location_id'] in location_ids for r in donors)
    assert all(r['location_id'] in location_ids for r in agents)
    assert all(r['hub_id'] in hub_ids for r in candidates)
    assert all(r['donation_id'] in donation_map for r in candidates)
    assert all(r['donation_id'] in donation_map for r in batch_members)
    assert len({b['donation_id'] for b in batch_members})==len(batch_members), 'Donation repeated in aggregation templates'
    for b in batch:
        members=[m for m in batch_members if m['batch_id']==b['batch_id']]
        assert len(members)==b['batch_item_count']
        assert round(sum(float(donation_map[m['donation_id']]['weight_kg']) for m in members),2)==b['batch_weight_kg']
        assert all(donation_map[m['donation_id']]['category']==b['batch_category'] for m in members)
    for r in candidates:
        if int(r['feasible_flag']):
            assert all(int(r[f])==1 for f in ('item_compatible_flag','capacity_feasible_flag','operating_feasible_flag','active_feasible_flag','route_available_flag'))
            assert r['reference_score'] != ''
        else: assert r['reference_score'] == ''
    active_states=collections.Counter(c['input_state'] for c in claim_states)
    route_listing_ids=[m['entity_id'] for m in s_members
                       if m['entity_type']=='LISTING' and m['scenario_id'].startswith('SCN-ROUTE_PLANNING-')]
    assert len(route_listing_ids) == 5*a.route_scenarios
    assert len(set(route_listing_ids)) == len(route_listing_ids)
    replacement_roles={(m['scenario_id'],m['entity_id']) for m in s_members
                       if m['scenario_role']=='POTENTIAL_REPLACEMENT_CLAIMANT'}
    assert sum(bool(any(sc==s['scenario_id'] for sc,_ in replacement_roles))
               for s in scenarios if s['scenario_type']=='LEASE_RECOVERY')==a.lease_scenarios
    assert len({c['listing_id'] for c in claim_states}) == len(claim_states), 'Lease fixtures overlap between replay cases'
    validation=dict(ngo_count=len(ngos),mapped_ngo_count=len(agents),
      scenario_type_counts=dict(collections.Counter(x['scenario_type'] for x in scenarios)),
      recommendation_feasible_groups=len(feasible_by),
      no_feasible_small_donations=len(edge),
      route_unavailable_candidate_pairs=sum(int(not x['route_available_flag']) for x in candidates),
      claim_input_states=dict(active_states),batch_member_duplicates=0,
      hub_capacity_violations=0,referential_integrity_passed=True,
      unwanted_origin_fields_excluded=True,
      distinct_route_listing_memberships=len(set(route_listing_ids)),
      lease_recovery_with_replacement=a.lease_scenarios,
      lease_active_with_replacement=25,route_reused_listing_count=0,
      route_scenarios=a.route_scenarios,hub_shortlist_size=HUB_SHORTLIST_SIZE)
    (out/'validation_summary.json').write_text(json.dumps(validation,indent=2)+'\n',encoding='utf8')
    for name,records in tables.items():write_csv(out,name,records)
    source_files={'population_district.csv':a.population,'NGO_references.csv':a.ngos,
                  'malaysia-singapore-brunei.osm.pbf':a.pbf}
    manifest=dict(benchmark_version=VERSION,seed=a.seed,created_at=dt.datetime.now(dt.timezone.utc).isoformat(),
        fixture_timezone='Asia/Kuala_Lumpur',fixture_epoch='2026-11-01T00:00',
        operating_boxes=OPERATING_BOXES,donor_max_straight_line_distance_to_reference_km=30,
        claim_design=dict(independent_replay_scenarios=a.claim_scenarios,possible_reused_initial_listings=True,minimum_eligible_identities=2,eligibility_design_radius_km=20,workers_are_requests_not_new_organisations=True,
           lease_recovery_positive_cases=a.lease_scenarios,active_lease_cases=25,
           distinct_replacement_identity_required=True,lease_selection_seed_offset=LEASE_SELECTION_SEED_OFFSET),
        route_sampling=dict(route_scenarios=a.route_scenarios,unique_direct_listings_per_scenario=5,
           unique_across_route_scenarios=True,ngo_assignment='round_robin_skipping_exhausted_catchments',
           profiles=['NORMAL','CAPACITY_PRESSURE','GEOGRAPHIC_SPREAD','CONNECTIVITY_STRESS'],
           candidate_distance_km=15,seed_offset=ROUTE_SELECTION_SEED_OFFSET),
        scenario_seed_semantics='full generator seed 20260915; independently seeded lease and route selection; scenario_seed identifies independent replay, not seed used in sampling',
        thesis_alignment_status='PENINSULAR_BOUNDARY_WITH_NGO_CATCHMENT_OPERATING_SUBSET',
        source_provenance={
            'population_district.csv':dict(source_url='https://data.gov.my/data-catalogue/population_district',retrieved_date=None,licence='CC BY 4.0',retrieval_status='ORIGINAL_RETRIEVAL_DATE_NOT_SUPPLIED'),
            'malaysia-singapore-brunei.osm.pbf':dict(source_url='https://download.geofabrik.de/asia/malaysia-singapore-brunei.html',retrieved_date=None,licence='ODbL 1.0',retrieval_status='ORIGINAL_RETRIEVAL_DATE_NOT_SUPPLIED'),
            'NGO_references.csv':dict(source_reference='dataset/NGO_references.csv',source_url=None,retrieved_date=None,licence=None,retrieval_status='UPSTREAM_PROVENANCE_NOT_SUPPLIED')},
        scenario_type_counts=dict(collections.Counter(s['scenario_type'] for s in scenarios)),
        hub_shortlisting=dict(candidate_count=HUB_SHORTLIST_SIZE,
            preselection='lowest Haversine distance, tie by hub ID',
            final_feasibility='item, capacity, opening overlap, active flag and directed OSM road availability',
            evaluation_distance='directed frozen OSM road distance; no straight-line fallback',
            caveat='nearest eight by straight line may exclude some road-near alternatives'),
        row_counts={name:len(r) for name,r in tables.items()},matrix_id=MATRIX,
        generated_csv_sha256={name:sha(out/(name+'.csv')) for name in tables},
        source_sha256={name:sha(path) for name,path in source_files.items()},
        road_cache_sha256={'nodes':sha(a.nodes),'edges':sha(a.edges),'osm_hub_candidates':sha(a.osm_hubs)},
        source_statement='User supplied NGO names/status/coordinates; sources and operational capacities not independently verified.',
        population_filter=dict(date='2025-01-01',sex='both',age='overall',ethnicity='overall',
                               source_unit='thousands',converted_unit='persons'),
        geographic_scope=dict(thesis='Peninsular Malaysia',generated_subset='17km OSM windows around all 11 supplied NGO coordinates in Peninsular Malaysia',
             donor_anchors='locality sampling using NGO/district proxies (not official polygons) and 30km NGO proximity',
             administrative_source='nearest declared NGO/locality district proxy; NOT an official administrative boundary'),
        generator_rules=dict(osm_amenities=['community_centre','townhall'],snap_radius_m=500,
            donation_weight_range_kg=[.5,30],boundary_weights_kg=[9.9,10,10.1],hub_capacity_range_kg=[50,250],
            hub_load_fraction_max=.8,hub_reserved_fraction_max=.2,batch_min_items=3,batch_max_items=5,
            batch_max_weight_kg=30,road_network='directed; no straight-line fallback',
            handling_penalties=HANDLING,scenario_sampling_nearby_radius_km=15,
            hub_shortlist_count=HUB_SHORTLIST_SIZE,
            hub_shortlist_preselection='eight nearest by Haversine, tie hub ID; hard checks and ranking use frozen directed roads',
            route_listing_reuse_across_scenarios=False,
            reclaim_scenario_requires_distinct_eligible_ngo=True,
            reference_policy_weights=dict(distance=.45,utilisation=.20,capacity_pressure=.25,handling=.10)),
        exclusions=['train-validation-test split','baseline algorithm and scores','claim commits','pickup task creation',
             'routing solutions','experiment worker count','lease duration configuration','route horizon',
             'actual donor behaviour','real NGO operational capacity'],
        limitations=['district labels for sampled locations are nearest-locality approximations, not official polygon assignments',
                     'road extracts cover NGO catchment regions, not the full Peninsular Malaysia road network',
                     'hub amenity does not certify an approved donation drop-off site',
                     'eight-Haversine-nearest candidate shortlist is a bounded preselection, not a globally exhaustive road-network ranking',
                     'NGO reference status is copied from supplied CSV, not independently confirmed',
                     f'{bad_site_count} OSM amenity candidates could not snap to selected road graph',
                     'synthetic operational attributes are not observed NGO or donor data'])
    (out/'generation_manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    print(json.dumps(dict(rows=manifest['row_counts'],types=manifest['scenario_type_counts']),indent=2),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--population',type=Path,default=INPUTS/'population_district.csv')
    p.add_argument('--ngos',type=Path,default=INPUTS/'NGO_references.csv')
    p.add_argument('--pbf',type=Path,default=INPUTS/'malaysia-singapore-brunei.osm.pbf')
    p.add_argument('--nodes',type=Path,default=CACHE/'road_nodes.csv')
    p.add_argument('--edges',type=Path,default=CACHE/'road_edges.csv')
    p.add_argument('--osm-hubs',type=Path,default=CACHE/'osm_hub_candidates.csv')
    p.add_argument('--output',type=Path,default=OUTPUT)
    p.add_argument('--seed',type=int,default=SEED)
    p.add_argument('--donations',type=int,default=3800)
    p.add_argument('--recommendation-scenarios',type=int,default=2000)
    p.add_argument('--claim-scenarios',type=int,default=150)
    p.add_argument('--lease-scenarios',type=int,default=100)
    p.add_argument('--aggregation-scenarios',type=int,default=100)
    p.add_argument('--route-scenarios',type=int,default=100)
    main(p.parse_args())
