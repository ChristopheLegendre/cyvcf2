#cython: profile=True
import os
import os.path as op
import sys
from collections import defaultdict
import atexit
import tempfile
import numpy as np
from array import array

from libc cimport stdlib
cimport numpy as np
np.seterr(invalid='ignore')
np.import_array()

from cython cimport view

from cpython.version cimport PY_MAJOR_VERSION

# overcome lack of __file__ in cython
import inspect
if not hasattr(sys.modules[__name__], '__file__'):
    __file__ = inspect.getfile(inspect.currentframe())



def par_relatedness(vcf_path, samples, ncpus, min_depth=5, each=1, sites=op.join(op.dirname(__file__), '1kg.sites')):
    from multiprocessing import Pool
    p = Pool(ncpus)

    ava = avn = avibs0 = avibs2 = n_samples = None
    for (fname, n) in p.imap(_par, [
        (vcf_path, samples, min_depth, i, ncpus, each, sites) for i in range(ncpus)]):

        arrays = np.load(fname)
        os.unlink(fname)
        va, vn, vibs0, vibs2 = arrays['va'], arrays['vn'], arrays['vibs0'], arrays['vibs2']

        if ava is None:
            ava, avn, avibs0, avibs2, n_samples = va, vn, vibs0, vibs2, n
        else:
            ava += va
            avn += vn
            avibs0 += vibs0
            avibs2 += vibs2

    return VCF(vcf_path, samples=samples)._relatedness_finish(ava[:n_samples, :n_samples],
                                             avn[:n_samples, :n_samples],
                                             avibs0[:n_samples, :n_samples],
                                             avibs2[:n_samples, :n_samples])


def _par(args):
    vcf_path, samples, min_depth, offset, ncpus, each, sites = args
    vcf = VCF(vcf_path, samples=samples, gts012=True)
    each = each * ncpus
    va, vn, vibs0, vibs2, n_samples, all_samples = vcf._site_relatedness(min_depth=min_depth, offset=offset, each=each, sites=sites)
    # to get around limits of multiprocessing size of transmitted data, we save
    # the arrays to disk and return the file
    fname = tempfile.mktemp(suffix=".npz")
    atexit.register(os.unlink, fname)
    np.savez_compressed(fname, va=np.asarray(va), vn=np.asarray(vn), vibs0=np.asarray(vibs0),
                        vibs2=np.asarray(vibs2))
    return fname, n_samples

cdef unicode xstr(s):
    if type(s) is unicode:
        # fast path for most common case(s)
        return <unicode>s
    elif PY_MAJOR_VERSION < 3 and isinstance(s, bytes):
        # only accept byte strings in Python 2.x, not in Py3
        return (<bytes>s).decode('ascii')
    elif isinstance(s, unicode):
        # an evil cast to <unicode> might work here in some(!) cases,
        # depending on what the further processing does.  to be safe,
        # we can always create a copy instead
        return unicode(s)
    else:
        raise TypeError(...)

def r_(int[::view.contiguous] a_gts, int[::view.contiguous] b_gts, float f, int32_t n_samples):
    return r_unphased(&a_gts[0], &b_gts[0], f, n_samples)


cdef class VCF(object):

    cdef htsFile *hts
    cdef const bcf_hdr_t *hdr
    cdef tbx_t *idx
    cdef hts_idx_t *hidx
    cdef int n_samples
    cdef int PASS
    cdef char *fname
    cdef bint gts012
    cdef bint lazy

    def add_to_header(self, line):
        ret = bcf_hdr_append(self.hdr, line)
        if ret != 0:
            raise Exception("couldn't add '%s' to header")
        ret = bcf_hdr_sync(self.hdr)
        if ret != 0:
            raise Exception("couldn't add '%s' to header")
        return ret

    def add_info_to_header(self, adict):
        return self.add_to_header("##INFO=<ID={ID},Number={Number},Type={Type},Description=\"{Description}\">".format(**adict))

    def add_format_to_header(self, adict):
        return self.add_to_header("##FORMAT=<ID={ID},Number={Number},Type={Type},Description=\"{Description}\">".format(**adict))

    def add_filter_to_header(self, adict):
        return self.add_to_header("##FILTER=<ID={ID},Description=\"{Description}\">".format(**adict))

    def __init__(self, fname, mode="r", gts012=False, lazy=False, samples=None):
        if fname == "-":
            fname = "/dev/stdin"
        if not op.exists(fname):
            raise Exception("bad path: %s" % fname)
        self.hts = hts_open(fname.encode(), mode.encode())
        cdef bcf_hdr_t *hdr
        hdr = self.hdr = bcf_hdr_read(self.hts)
        if samples is not None:
            self.set_samples(samples)
        self.n_samples = bcf_hdr_nsamples(self.hdr)
        self.PASS = -1
        self.fname = fname
        self.gts012 = gts012
        self.lazy = lazy

    def set_samples(self, samples):
        if samples is None:
            samples = "-"
        if isinstance(samples, list):
            samples = ",".join(samples)

        ret = bcf_hdr_set_samples(self.hdr, samples.encode(), 0)
        assert ret >= 0, ("error setting samples", ret)
        if ret != 0 and samples != "-":
            s = samples.split(",")
            if ret < len(s):
                sys.stderr.write("problem with sample: %s\n" % s[ret - 1])

    def update(self, id, type, number, description):
        ret = bcf_hdr_append(self.hdr, "##INFO=<ID={id},Number={number},Type={type},Description=\"{description}\">".format(id=id, type=type, number=number, description=description))
        if ret != 0:
            raise Exception("unable to update to header: %d", ret)
        ret = bcf_hdr_sync(self.hdr)
        if ret != 0:
            raise Exception("unable to update to header")

    def __call__(VCF self, region=None):
        if not region:
            yield from self
            raise StopIteration

        if self.idx == NULL:
            # we load the index on first use if possible and re-use
            if not op.exists(str(self.fname + ".tbi")): #  or os.path.exists(self.name + ".csi"):
                raise Exception("can't extract region without tabix or csi index for %s" % self.fname)

            if op.exists(self.fname + ".tbi"):
                self.idx = tbx_index_load(self.fname + b".tbi")
                assert self.idx != NULL, "error loading tabix index for %s" % self.fname
            #else:
            #    self.hidx = bcf_index_load(self.fname)
            #    assert self.hidx != NULL, "error loading csi index for %s" % self.fname

        cdef hts_itr_t *itr
        cdef kstring_t s
        cdef bcf1_t *b
        cdef int slen, ret

        itr = tbx_itr_querys(self.idx, region)
        if itr == NULL:
            sys.stderr.write("no intervals found for %s at %s\n" % (self.fname, region))
            raise StopIteration
        try:
            slen = tbx_itr_next(self.hts, self.idx, itr, &s)
            while slen > 0:
                b = bcf_init()
                ret = vcf_parse(&s, self.hdr, b)
                if ret > 0:
                    raise Exception("error parsing")
                yield newVariant(b, self)
                slen = tbx_itr_next(self.hts, self.idx, itr, &s)
        finally:
            stdlib.free(s.s)
            hts_itr_destroy(itr)

    def header_iter(self):
        cdef int i
        for i in range(self.hdr.nhrec):
            yield newHREC(self.hdr.hrec[i], self.hdr)

    def ibd(self, int nmax=-1):
        assert self.gts012
        import itertools

        cdef int i, rl, n_bins = 16

        samples = self.samples
        sample_to_idx = {s: samples.index(s) for s in samples}
        sample_pairs = list(itertools.combinations(samples, 2))
        # values of bins, run_length

        cdef int n = 0
        cdef float pi
        cdef int[:] b
        cdef int[:] gts
        bins = np.zeros((len(sample_pairs), n_bins), dtype=np.int32)
        rls = np.zeros(len(sample_pairs), dtype=np.int32)

        for v in self:
            if n == nmax: break
            n += 1
            gts = v.gt_types
            pi = v.aaf
            for i, (s0, s1) in enumerate(sample_pairs):
                b = bins[i, :]
                idx0, idx1 = sample_to_idx[s0], sample_to_idx[s1]
                rls[i] = ibd(gts[idx0], gts[idx1], rls[i], pi, &b[0], n_bins)

        return {sample_pairs[i]: bins[i, :] for i in range(len(sample_pairs))}

    # pull something out of the HEADER, e.g. CSQ
    def __getitem__(self, char *key):
        cdef bcf_hrec_t *b = bcf_hdr_get_hrec(self.hdr, BCF_HL_INFO, b"ID", key, NULL);
        cdef int i
        if b == NULL:
            b = bcf_hdr_get_hrec(self.hdr, BCF_HL_GEN, key, NULL, NULL);
            if b == NULL:
                raise KeyError
            d = {b.key: b.value}
        else:
            d =  {b.keys[i]: b.vals[i] for i in range(b.nkeys)}
        #bcf_hrec_destroy(b)
        return d

    def __contains__(self, char *key):
        try:
            self[key]
            return True
        except KeyError:
            return False

    contains = __contains__


    def __dealloc__(self):
        if self.hdr != NULL:
            bcf_hdr_destroy(self.hdr)
            self.hdr = NULL
        if self.hts != NULL:
            hts_close(self.hts)
            self.hts = NULL
        if self.idx != NULL:
            tbx_destroy(self.idx)
        if self.hidx != NULL:
            hts_idx_destroy(self.hidx)

    def __iter__(self):
        return self

    def __next__(self):

        cdef bcf1_t *b = bcf_init()
        cdef int ret
        with nogil:
            ret = bcf_read(self.hts, self.hdr, b)
        if ret >= 0:
            return newVariant(b, self)
        else:
            bcf_destroy(b)
        raise StopIteration

    property samples:
        def __get__(self):
            cdef int i
            return [self.hdr.samples[i] for i in range(self.n_samples)]

    property raw_header:
        def __get__(self):
            cdef int hlen
            s = bcf_hdr_fmt_text(self.hdr, 0, &hlen)
            return s

    def plot_relatedness(self, riter):
        import pandas as pd
        from matplotlib import pyplot as plt
        from matplotlib import gridspec
        import seaborn as sns
        sns.set_style("ticks")

        df = []
        for row in riter:
          row['jtags'] = '|'.join(row['tags'])
          df.append(row)


        df = pd.DataFrame(df)
        fig = plt.figure(figsize=(9, 9))

        gs = gridspec.GridSpec(2, 1, height_ratios=[3.5, 1])

        ax0, ax1 = plt.subplot(gs[0]), plt.subplot(gs[1])

        if "error" in df.columns:
            # plot all gray except points that don't match our expectation.
            import matplotlib
            matplotlib.rcParams['pdf.fonttype'] = 42
            import matplotlib.colors as mc
            colors = [mc.hex2color(h) for h in ('#b6b6b6', '#ff3333')]
            for i, err in enumerate(("ok", "error")):
                subset = df[df.error == err]
                subset.plot(kind='scatter', x='rel', y='ibs0', c=colors[i],
                          edgecolor=colors[0],
                          label=err, ax=ax0, s=17 if i == 0 else 35)
            sub = df[df.error == "error"]
            for i, row in sub.iterrows():
                ax0.annotate(row['sample_a'] + "\n" + row['sample_b'],
                        (row['rel'], row['ibs0']), fontsize=8)
        else:
            # color by the relation derived from the genotypes.
            colors = sns.color_palette("Set1", len(set(df.jtags)))
            for i, tag in enumerate(set(df.jtags)):
                subset = df[df.jtags == tag]
                subset.plot(kind='scatter', x='rel', y='ibs0', c=colors[i],
                          label=tag, ax=ax0)

            ax0.legend()

        ax0.set_ylim(ymin=0)
        ax0.set_xlim(xmin=df.rel.min())

        ax1.set_xlim(*ax0.get_xlim())
        ax1.hist(df.rel, 40)
        ax1.set_yscale('log', nonposy='clip')
        return fig

    def gen_variants(self, sites=op.join(op.dirname(__file__), '1kg.sites'),
                    offset=0, each=1):
    
        cdef int all_samples = len(self.samples)
        extras = None
        if sites is not None:
            isites = []
            for i in (x.strip().split(":") for x in open(sites)):
                i[1] = int(i[1])
                isites.append(i)

            import gzip
            f = sites + ".bin.gz"
            if op.exists(f):
                tmp = np.fromstring(gzip.open(f).read(), dtype=np.uint8).astype(np.int32)
                rows = len(isites)
                cols = len(tmp) / rows
                extras = tmp.reshape((rows, cols))
                del tmp
                all_samples += cols
            else:
                sys.stderr.write("didn't find extra samples in site_relatedness; using sample from vcf only\n")

        cdef Variant v
        cdef int k, last_pos
        if sites:
            isites = isites[offset::each]
            extras = extras[offset::each, :]
            def gen():
                for i, (chrom, pos, ref, alt) in enumerate(isites):
                    for v in self("%s:%s-%s" % (chrom, pos, pos)):
                        if v.REF != ref: continue
                        if len(v.ALT) != 1: continue
                        if v.ALT[0] != alt: continue
                        yield i, v
                        break
        else:
            def gen():
                last_pos, k = -10000, 0
                for v in self:
                    if abs(v.POS - last_pos) < 5000: continue
                    if len(v.REF) != 1: continue
                    if len(v.ALT) != 1: continue
                    if v.call_rate < 0.5: continue
                    if not 0.03 < v.aaf < 0.6: continue
                    if np.mean(v.gt_depths > 7) < 0.5: continue
                    last_pos = v.POS
                    if k >= offset and k % each == 0:
                        yield k, v
                    k += 1
                    if k > 20000: break
        return all_samples, extras, gen

    def het_check(self, min_depth=8, percentiles=(10, 90)):

        cdef int i, k, n_samples = len(self.samples), j = 0
        cdef Variant v
        cdef np.ndarray het_counts = np.zeros((n_samples,), dtype=np.int32)

        cdef np.ndarray sum_depths = np.zeros((n_samples,), dtype=np.int32)
        cdef np.ndarray sum_counts = np.zeros((n_samples,), dtype=np.int32)
        cdef int any_counts = 0

        mean_depths = []

        _, _, gen = self.gen_variants()
        maf_lists = defaultdict(list)
        idxs = np.arange(n_samples)
        for i, v in gen():
            if v.CHROM in ('X', 'chrX'): break
            if v.aaf < 0.01: continue
            if v.call_rate < 0.5: continue
            j += 1
            alts = v.gt_alt_depths
            assert len(alts) == n_samples
            depths = (alts + v.gt_ref_depths)
            sum_depths += depths
            sum_counts += (depths > min_depth)
            any_counts += 1
            mean_depths.append(depths)

            mafs = alts / depths.astype(float)
            gt_types = v.gt_types
            hets = gt_types == 1
            het_counts[hets] += 1
            for k in idxs[hets]:
                if depths[k] <= min_depth: continue
                maf_lists[k].append(mafs[k])

        mean_depths = np.array(mean_depths).T

        sample_ranges = {}
        for i, sample in enumerate(self.samples):
            qs = np.asarray(np.percentile(maf_lists[i] or [0], percentiles))
            sample_ranges[sample] = dict(zip(['p' + str(p) for p in percentiles], qs))
            sample_ranges[sample]['range'] = qs.max() - qs.min()
            sample_ranges[sample]['het_ratio'] = het_counts[i] / float(j)
            sample_ranges[sample]['het_count'] = het_counts[i]
            sample_ranges[sample]['sampled_sites'] = sum_counts[i]
            sample_ranges[sample]['mean_depth'] = np.mean(mean_depths[i])
            sample_ranges[sample]['median_depth'] = np.median(mean_depths[i])

        return sample_ranges


    def site_relatedness(self, sites=op.join(op.dirname(__file__), '1kg.sites'),
                         min_depth=5, each=1):

        va, vn, vibs0, vibs2, n_samples, all_samples = self._site_relatedness(sites=sites, min_depth=min_depth, each=each)
        if n_samples != all_samples:
            return self._relatedness_finish(va[:n_samples, :n_samples],
                                            vn[:n_samples, :n_samples],
                                            vibs0[:n_samples, :n_samples],
                                            vibs2[:n_samples, :n_samples])
        return self._relatedness_finish(va, vn, vibs0, vibs2)


    cdef _site_relatedness(self, sites=op.join(op.dirname(__file__), '1kg.sites'),
            min_depth=5, each=1, offset=0):
        """
        sites must be an file of format: chrom:pos1:ref:alt where
        we match on all parts.
        it must have a matching file with a suffix of .bin.gz that is the binary
        genotype data. with 0 == hom_ref, 1 == het, 2 == hom_alt, 3 == unknown.
        min_depth applies per-sample
        """
        cdef int n_samples = len(self.samples)
        cdef int all_samples
        cdef int k, i
        cdef int32_t[:, ::view.contiguous] extras
        assert each >= 0

        all_samples, extras, gen = self.gen_variants(sites, offset=offset, each=each)

        cdef double[:, ::view.contiguous] va = np.zeros((all_samples, all_samples), np.float64)
        cdef int32_t[:, ::view.contiguous] vn = np.zeros((all_samples, all_samples), np.int32)
        cdef int32_t[:, ::view.contiguous] vibs0 = np.zeros((all_samples, all_samples), np.int32)
        cdef int32_t[:, ::view.contiguous] vibs2 = np.zeros((all_samples, all_samples), np.int32)
        cdef int32_t[:] all_gt_types = np.zeros((all_samples, ), np.int32)
        cdef int32_t[:] depths = np.zeros((n_samples, ), np.int32)

        cdef Variant v

        for j, (i, v) in enumerate(gen()):
            if n_samples != all_samples:
                v.gt_types
                depths = v.gt_depths
                for k in range(n_samples):
                    all_gt_types[k] = v._gt_types[k]
                    if depths[k] < min_depth:
                        all_gt_types[k] = 3 # UNKNOWN
                all_gt_types[n_samples:] = extras[i, :]
                v.relatedness_extra(va, vn, vibs0, vibs2, all_gt_types, all_samples)
            else:
                v.relatedness(va, vn, vibs0, vibs2)

        return va, vn, vibs0, vibs2, n_samples, all_samples

    def relatedness(self, int n_variants=35000, int gap=30000, float min_af=0.04,
                    float max_af=0.8, float linkage_max=0.2, min_depth=8):

        cdef Variant v

        cdef int last = -gap, nv = 0, nvt=0
        cdef int *last_gts
        samples = self.samples
        cdef int n_samples = len(samples)
        cdef float aaf
        cdef int n_unlinked = 0

        cdef double[:, ::view.contiguous] va = np.zeros((n_samples, n_samples), np.float64)
        cdef int32_t[:, ::view.contiguous] vn = np.zeros((n_samples, n_samples), np.int32)
        cdef int32_t[:, ::view.contiguous] vibs0 = np.zeros((n_samples, n_samples), np.int32)
        cdef int32_t[:, ::view.contiguous] vibs2 = np.zeros((n_samples, n_samples), np.int32)

        for v in self:
            nvt += 1
            if last_gts == NULL:
                if v._gt_types == NULL:
                    v.gt_types
                last_gts = v._gt_types
            if v.POS - last < gap and v.POS > last:
                continue
            if v.call_rate < 0.5: continue
            # require half of the samples to meet the min depth
            if np.mean(v.gt_depths > min_depth) < 0.5: continue
            aaf = v.aaf
            if aaf < min_af: continue
            if aaf > max_af: continue
            if linkage_max < 1 and v.POS - last < 40000:
                if v._gt_types == NULL:
                    v.gt_types
                # require 5 unlinked variants
                if r_unphased(last_gts, v._gt_types, 1e-5, n_samples) > linkage_max:
                    continue
                n_unlinked += 1
                if n_unlinked < 5:
                    continue

            n_unlinked = 0

            if v._gt_types == NULL:
                v.gt_types
            last, last_gts = v.POS, v._gt_types

            v.relatedness(va, vn, vibs0, vibs2)
            nv += 1
            if nv == n_variants:
                break
        sys.stderr.write("tested: %d variants out of %d\n" % (nv, nvt))
        return self._relatedness_finish(va, vn, vibs0, vibs2)

    cdef dict _relatedness_finish(self, double[:, ::view.contiguous] va,
                                        int32_t[:, ::view.contiguous] vn,
                                        int32_t[:, ::view.contiguous] vibs0,
                                        int32_t[:, ::view.contiguous] vibs2):
        samples = self.samples
        n = np.asarray(vn)
        a = np.asarray(va)
        ibs0, ibs2 = np.asarray(vibs0, a.dtype), np.asarray(vibs2, a.dtype)
        # the counts only went to the upper diagonal. translate to lower for
        # ibs2*
        n[np.tril_indices(len(n))] = n[np.triu_indices(len(n))]

        a /= n
        ibs0 = ibs0 / n
        ibs2 = ibs2 / n


        cdef int sj, sk
        res = {'sample_a': [], 'sample_b': [], 'rel': array('f'),
               'ibs0': array('f'), 'n': array('I'), 'ibs2' : array('f')}

        for sj, sample_j in enumerate(samples):
            for sk, sample_k in enumerate(samples[sj:], start=sj):
                if sj == sk: continue

                rel, iibs0, iibs2 = a[sj, sk], ibs0[sj, sk], ibs2[sj, sk]
                iibs2_star = ibs2[sk, sj]
                res['sample_a'].append(sample_j)
                res['sample_b'].append(sample_k)
                res['rel'].append(rel)
                res['ibs0'].append(iibs0)
                res['ibs2'].append(iibs2)
                res['n'].append(n[sj, sk])
        return res

cdef class Variant(object):
    cdef bcf1_t *b
    cdef VCF vcf
    cdef int *_gt_types
    cdef int *_gt_ref_depths
    cdef int *_gt_alt_depths
    cdef void *fmt_buffer
    cdef int *_gt_phased
    cdef float *_gt_quals
    cdef int *_int_gt_quals
    cdef int *_gt_idxs
    cdef int _gt_nper
    cdef int *_gt_pls
    cdef float *_gt_gls
    cdef readonly INFO INFO
    cdef int _ploidy

    cdef readonly int POS

    def __cinit__(self):
        self.b = NULL
        self._gt_types = NULL
        self._gt_phased = NULL
        self._gt_pls = NULL
        self._ploidy = -1

    def __repr__(self):
        return "Variant(%s:%d %s/%s)" % (self.CHROM, self.POS, self.REF,
                ",".join(self.ALT))

    def __str__(self):
        cdef kstring_t s
        s.s, s.l, s.m = NULL, 0, 0
        vcf_format(self.vcf.hdr, self.b, &s)
        st = ks_release(&s)
        return st.decode()

    def __dealloc__(self):
        if self.b is not NULL:
            bcf_destroy(self.b)
            self.b = NULL
        if self._gt_types != NULL:
            stdlib.free(self._gt_types)
        if self._gt_ref_depths != NULL:
            stdlib.free(self._gt_ref_depths)
        if self._gt_alt_depths != NULL:
            stdlib.free(self._gt_alt_depths)
        if self._gt_phased != NULL:
            stdlib.free(self._gt_phased)
        if self._gt_quals != NULL:
            stdlib.free(self._gt_quals)
        if self._int_gt_quals != NULL:
            stdlib.free(self._int_gt_quals)
        if self._gt_idxs != NULL:
            stdlib.free(self._gt_idxs)
        if self._gt_pls != NULL:
            stdlib.free(self._gt_pls)
        if self._gt_gls != NULL:
            stdlib.free(self._gt_gls)

    property gt_bases:
        def __get__(self):
            if self._gt_idxs == NULL:
                self.gt_types
            cdef int i, n = self.ploidy, j=0, k
            cdef char **alleles = self.b.d.allele
            #cdef dict d = {i:alleles[i] for i in range(self.b.n_allele)}
            cdef list d = [alleles[i] for i in range(self.b.n_allele)]
            d.append(".") # -1 gives .
            cdef list a = []
            cdef list phased = list(self.gt_phases)
            cdef char **lookup = ["/", "|"]
            for i in range(0, n * self.vcf.n_samples, n):
                if n == 2:
                    a.append(d[self._gt_idxs[i]] +
                             lookup[phased[j]] +
                             d[self._gt_idxs[i+1]])
                elif n == 1:
                    a.append(d[self._gt_idxs[i]])
                else:
                    raise Exception("gt_bases not implemented for ploidy > 2")

                j += 1
            return np.array(a, np.str)

    cpdef relatedness(self, double[:, ::view.contiguous] asum,
                          int32_t[:, ::view.contiguous] n,
                          int32_t[:, ::view.contiguous] ibs0,
                          int32_t[:, ::view.contiguous] ibs2):
        if not self.vcf.gts012:
            raise Exception("must call relatedness with gts012")
        if self._gt_types == NULL:
            self.gt_types
        cdef int n_samples = self.vcf.n_samples
        return related(self._gt_types, &asum[0, 0], &n[0, 0], &ibs0[0, 0],
                       &ibs2[0, 0], n_samples)

    cdef int relatedness_extra(self, double[:, ::view.contiguous] asum,
                          int32_t[:, ::view.contiguous] n,
                          int32_t[:, ::view.contiguous] ibs0,
                          int32_t[:, ::view.contiguous] ibs2,
                          int32_t[:] all_gt_types,
                          int n_samples_total):
        if not self.vcf.gts012:
            raise Exception("must call relatedness with gts012")
        if self._gt_types == NULL:
            self.gt_types

        ret = related(<int *>&all_gt_types[0], &asum[0, 0], &n[0, 0], &ibs0[0, 0],
                      &ibs2[0, 0], n_samples_total)

    property num_called:
        def __get__(self):
            if self._gt_types == NULL:
                self.gt_types
            cdef int n = 0, i = 0
            if self.vcf.gts012:
                for i in range(self.vcf.n_samples):
                    if self._gt_types[i] != 3:
                        n+=1
            else:
                for i in range(self.vcf.n_samples):
                    if self._gt_types[i] != 2:
                        n+=1
            return n

    property call_rate:
        def __get__(self):
            if self.vcf.n_samples > 0:
                return float(self.num_called) / self.vcf.n_samples

    property aaf:
        def __get__(self):
            num_chroms = 2.0 * self.num_called
            if num_chroms == 0.0:
                return 0.0
            return float(self.num_het + 2 * self.num_hom_alt) / num_chroms

    property nucl_diversity:
        def __get__(self):
            num_chroms = 2.0 * self.num_called
            p = self.aaf
            return (num_chroms / (num_chroms - 1.0)) * 2 * p * (1 - p)

    property num_hom_ref:
        def __get__(self):
            if self._gt_types == NULL:
                self.gt_types
            cdef int n = 0, i = 0
            for i in range(self.vcf.n_samples):
                if self._gt_types[i] == 0:
                    n+=1
            return n

    property num_het:
        def __get__(self):
            if self._gt_types == NULL:
                self.gt_types
            cdef int n = 0, i = 0
            for i in range(self.vcf.n_samples):
                if self._gt_types[i] == 1:
                    n+=1
            return n

    property num_hom_alt:
        def __get__(self):
            if self._gt_types == NULL:
                self.gt_types
            cdef int n = 0, i = 0
            if self.vcf.gts012:
                for i in range(self.vcf.n_samples):
                    if self._gt_types[i] == 2:
                        n+=1
            else:
                for i in range(self.vcf.n_samples):
                    if self._gt_types[i] == 3:
                        n+=1
            return n

    property num_unknown:
        def __get__(self):
            if self._gt_types == NULL:
                self.gt_types
            cdef int n = 0, i = 0
            for i in range(self.vcf.n_samples):
                if self._gt_types[i] == 2:
                    n+=1
            return n

    def format(self, tag, vtype=None):
        """
        type is one of [int, float, str]
        TODO: get vtype from header
        returns None on error.
        """
        cdef bcf_fmt_t *fmt = bcf_get_fmt(self.vcf.hdr, self.b, tag)
        cdef int n, nret
        cdef void *buf = NULL;
        cdef int typenum = 0
        if vtype == int:
            nret = bcf_get_format_int32(self.vcf.hdr, self.b, tag, <int **>&buf, &n)
            typenum = np.NPY_INT32
        elif vtype == float:
            nret = bcf_get_format_float(self.vcf.hdr, self.b, tag, <float **>&buf, &n)
            typenum = np.NPY_FLOAT32
        elif vtype == str:
            nret = bcf_get_format_string(self.vcf.hdr, self.b, tag, <char ***>&buf, &n)
            typenum = np.NPY_STRING
        else:
            raise Exception("type %s not supported to format()" % vtype)
        if nret < 0:
            return None

        cdef np.npy_intp shape[2]
        shape[0] = <np.npy_intp> self.vcf.n_samples
        shape[1] = fmt.n # values per sample
        v = np.PyArray_SimpleNewFromData(2, shape, typenum, buf)
        ret = np.array(v)
        if vtype == str:
            stdlib.free(&buf[0])
        stdlib.free(buf)
        return ret

    property gt_types:
        def __get__(self):
            cdef int ndst, ngts, n, i, nper, j = 0, k = 0
            cdef int a
            if self.vcf.n_samples == 0:
                return []
            if self._gt_types == NULL:
                self._gt_phased = <int *>stdlib.malloc(sizeof(int) * self.vcf.n_samples)
                ndst = 0
                ngts = bcf_get_genotypes(self.vcf.hdr, self.b, &self._gt_types, &ndst)
                nper = ndst / self.vcf.n_samples
                self._ploidy = nper
                self._gt_idxs = <int *>stdlib.malloc(sizeof(int) * self.vcf.n_samples * nper)
                for i in range(0, ndst, nper):
                    for k in range(i, i + nper):
                        a = self._gt_types[k]
                        if a >= 0:
                            self._gt_idxs[k] = bcf_gt_allele(a)
                        else:
                            self._gt_idxs[k] = a

                    self._gt_phased[j] = self._gt_types[i] > 0 and <int>bcf_gt_is_phased(self._gt_types[i+1])
                    j += 1

                #print [self._gt_types[x] for x in range(self.vcf.n_samples * nper)]
                if self.vcf.gts012:
                    n = as_gts012(self._gt_types, self.vcf.n_samples, nper)
                else:
                    n = as_gts(self._gt_types, self.vcf.n_samples, nper)
            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self.vcf.n_samples
            return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32, self._gt_types)

    property ploidy:
        def __get__(self):
            if self._ploidy == -1:
                self.gt_types
            return self._ploidy

    property gt_phred_ll_homref:
        def __get__(self):
            if self.vcf.n_samples == 0:
                return []
            cdef int ndst = 0, nret=0, n, i, j, nper

            cdef int imax = np.iinfo(np.int32(0)).max

            if self._gt_pls == NULL and self._gt_gls == NULL:
                nret = bcf_get_format_int32(self.vcf.hdr, self.b, "PL", &self._gt_pls, &ndst)
                if nret < 0:
                    nret = bcf_get_format_float(self.vcf.hdr, self.b, "GL", &self._gt_gls, &ndst)
                    if nret < 0:
                        return []
                    else:
                        for i in range(nret):
                            if self._gt_gls[i] <= -2147483646:
                                # this gets translated on conversion to PL
                                self._gt_gls[i] = imax / -10.0
                else:
                    for i in range(nret):
                        if self._gt_pls[i] < 0:
                            self._gt_pls[i] = imax

                self._gt_nper = nret / self.vcf.n_samples
            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self._gt_nper * self.vcf.n_samples
            if self._gt_pls != NULL:
                pls = np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32,
                        self._gt_pls)[::self._gt_nper]
                return pls
            else:
                gls = np.PyArray_SimpleNewFromData(1, shape, np.NPY_FLOAT32,
                        self._gt_gls)[::self._gt_nper]
                gls = (-10 * gls).round().astype(np.int32)
                return gls

    property gt_phred_ll_het:
        def __get__(self):
            if self.vcf.n_samples == 0:
                return []
            if self._gt_pls == NULL and self._gt_gls == NULL:
                # NOTE: the missing values for all homref, het, homalt are set
                # by this call.
                self.gt_phred_ll_homref
            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self._gt_nper * self.vcf.n_samples
            if self._gt_pls != NULL:
                if self._gt_nper > 1:
                    ret = np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32, self._gt_pls)[1::self._gt_nper]
                    return ret

                return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32, self._gt_pls)
            else:
                if self._gt_nper > 1:
                    gls = np.PyArray_SimpleNewFromData(1, shape, np.NPY_FLOAT32,
                            self._gt_gls)[1::self._gt_nper]
                else:
                    gls = np.PyArray_SimpleNewFromData(1, shape, np.NPY_FLOAT32, self._gt_gls)
                gls = (-10 * gls).round().astype(np.int32)
                return gls

    property gt_phred_ll_homalt:
        def __get__(self):
            if self.vcf.n_samples == 0:
                return []
            if self._gt_pls == NULL and self._gt_gls == NULL:
                self.gt_phred_ll_homref
            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self._gt_nper * self.vcf.n_samples
            if self._gt_pls != NULL:
                if self._gt_nper > 1:
                    return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32,
                            self._gt_pls)[2::self._gt_nper]
                return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32, self._gt_pls)
            else:
                if self._gt_nper > 1:
                    gls = np.PyArray_SimpleNewFromData(1, shape, np.NPY_FLOAT32,
                            self._gt_gls)[2::self._gt_nper]
                else:
                    gls = np.PyArray_SimpleNewFromData(1, shape, np.NPY_FLOAT32,
                            self._gt_gls)
                gls = (-10 * gls).round().astype(np.int32)
                return gls

    property gt_ref_depths:
        def __get__(self):
            cdef int ndst, nret = 0, n, i, j = 0, nper = 0
            if self.vcf.n_samples == 0:
                return []
            if self._gt_ref_depths == NULL:
                ndst = 0
                # GATK
                nret = bcf_get_format_int32(self.vcf.hdr, self.b, "AD", &self._gt_ref_depths, &ndst)
                if nret > 0:
                    nper = nret / self.vcf.n_samples
                    if nper == 1:
                        stdlib.free(self._gt_ref_depths); self._gt_ref_depths = NULL
                        return -1 + np.zeros(self.vcf.n_samples, np.int32)

                    for i in range(0, nret, nper):
                        self._gt_ref_depths[j] = self._gt_ref_depths[i]
                        j += 1
                elif nret == -1:
                    # Freebayes
                    # RO has to be 1:1
                    nret = bcf_get_format_int32(self.vcf.hdr, self.b, "RO", &self._gt_ref_depths, &ndst)
                    if nret < 0:
                        stdlib.free(self._gt_ref_depths); self._gt_ref_depths = NULL
                        return -1 + np.zeros(self.vcf.n_samples, np.int32)
                # TODO: add new vcf standard.
                else:
                    stdlib.free(self._gt_ref_depths); self._gt_ref_depths = NULL
                    return -1 + np.zeros(self.vcf.n_samples, np.int32)

                for i in range(self.vcf.n_samples):
                    if self._gt_ref_depths[i] < 0:
                        self._gt_ref_depths[i] = -1
            else:
                pass

            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self.vcf.n_samples
            return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32, self._gt_ref_depths)


    property gt_alt_depths:
        def __get__(self):
            cdef int ndst, nret = 0, n, i, j = 0, k = 0, nper = 0
            if self.vcf.n_samples == 0:
                return []
            if self._gt_alt_depths == NULL:
                ndst = 0
                # GATK
                nret = bcf_get_format_int32(self.vcf.hdr, self.b, "AD", &self._gt_alt_depths, &ndst)
                if nret > 0:
                    nper = nret / self.vcf.n_samples
                    if nper == 1:
                        stdlib.free(self._gt_alt_depths); self._gt_alt_depths = NULL
                        return (-1 + np.zeros(self.vcf.n_samples, np.int32))

                    for i in range(0, nret, nper):
                        self._gt_alt_depths[j] = self._gt_alt_depths[i+1]
                        # add up all the alt alleles
                        for k in range(2, nper):
                            self._gt_alt_depths[j] += self._gt_alt_depths[i+k]
                        j += 1

                elif nret == -1:
                    # Freebayes
                    nret = bcf_get_format_int32(self.vcf.hdr, self.b, "AO", &self._gt_alt_depths, &ndst)
                    nper = nret / self.vcf.n_samples
                    if nret < 0:
                        stdlib.free(self._gt_alt_depths); self._gt_alt_depths = NULL
                        return -1 + np.zeros(self.vcf.n_samples, np.int32)
                    for i in range(0, nret, nper):
                        self._gt_alt_depths[j] = self._gt_alt_depths[i]
                        for k in range(1, nper):
                            self._gt_alt_depths[j] += self._gt_alt_depths[i+k]
                        j += 1
                else:
                    stdlib.free(self._gt_alt_depths); self._gt_alt_depths = NULL
                    return -1 + np.zeros(self.vcf.n_samples, np.int32)

                # TODO: add new vcf standard.
            for i in range(self.vcf.n_samples):
                if self._gt_alt_depths[i] < 0:
                    self._gt_alt_depths[i] = -1

            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self.vcf.n_samples
            return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32, self._gt_alt_depths)

    property gt_quals:
        def __get__(self):
            if self.vcf.n_samples == 0:
                return []
            cdef int ndst = 0, nret, n, i
            cdef int *gq
            cdef np.ndarray[np.float32_t, ndim=1] a
            if self._gt_quals == NULL and self._int_gt_quals == NULL:
                nret = bcf_get_format_int32(self.vcf.hdr, self.b, "GQ", &self._int_gt_quals, &ndst)
                if nret == -2: # defined as int
                    ndst = 0
                    nret = bcf_get_format_float(self.vcf.hdr, self.b, "GQ", &self._gt_quals, &ndst)
                if nret < 0 and nret != -2:
                    return -1.0 + np.zeros(self.vcf.n_samples, np.float32)
            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self.vcf.n_samples
            if self._int_gt_quals != NULL:
                a = np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32, self._int_gt_quals).astype(np.float32)
                a[a < 0] = -1
            else:
                a = np.PyArray_SimpleNewFromData(1, shape, np.NPY_FLOAT32, self._gt_quals)
                # this take up 10% of the total vcf parsing time. fix!!
                a[np.isnan(a)] = -1
            return a

    property gt_depths:
        def __get__(self):
            if self.vcf.n_samples == 0:
                return []
            # unfortunately need to create a new array here since we're modifying.
            r = np.array(self.gt_ref_depths, np.int32)
            a = np.array(self.gt_alt_depths, np.int32)
            # keep the -1 for empty.
            rl0 = r < 0
            al0 = a < 0
            r[rl0] = 0
            a[al0] = 0
            depth = r + a
            depth[rl0 & al0] = -1
            return depth

    property gt_phases:
        def __get__(self):
            # run for side-effect
            if self._gt_phased == NULL:
                self.gt_types
            cdef np.npy_intp shape[1]
            shape[0] = <np.npy_intp> self.vcf.n_samples

            return np.PyArray_SimpleNewFromData(1, shape, np.NPY_INT32, self._gt_phased).astype(bool)


    property REF:
        def __get__(self):
            return self.b.d.allele[0]

    property ALT:
        def __get__(self):
            cdef int i
            return [self.b.d.allele[i] for i in range(1, self.b.n_allele)]

    property is_snp:
        def __get__(self):
            cdef int i
            if len(self.b.d.allele[0]) > 1: return False
            for i in range(1, self.b.n_allele):
                if not self.b.d.allele[i] in (b"A", b"C", b"G", b"T"):
                    return False
            return True

    property is_indel:
        def __get__(self):
            cdef int i
            is_sv = self.is_sv
            if len(self.b.d.allele[0]) > 1 and not is_sv: return True

            if len(self.REF) > 1 and not is_sv: return True

            for i in range(1, self.b.n_allele):
                alt = self.b.d.allele[i]
                if alt == b".":
                    return True
                if len(alt) != len(self.REF):
                    if not is_sv:
                        return True
            return False

    property is_transition:
        def __get__(self):
            if len(self.ALT) > 1: return False

            if not self.is_snp: return False
            ref = self.REF
                # just one alt allele
            alt_allele = self.ALT[0]
            if ((ref == b'A' and alt_allele == b'G') or
                (ref == b'G' and alt_allele == b'A') or
                (ref == b'C' and alt_allele == b'T') or
                (ref == b'T' and alt_allele == b'C')):
                    return True
            return False

    property is_deletion:
        def __get__(self):
            if len(self.ALT) > 1: return False

            if not self.is_indel: return False
            alt = self.ALT[0]
            if alt is None or alt == ".":
                return True

            if len(self.REF) > len(alt):
                return True
            return False

    property is_sv:
        def __get__(self):
            return self.INFO.get(b'SVTYPE') is not None

    property CHROM:
        def __get__(self):
            return bcf_hdr_id2name(self.vcf.hdr, self.b.rid)

    property var_type:
        def __get__(self):
           if self.is_snp:
               return "snp"
           elif self.is_indel:
               return "indel"
           elif self.is_sv:
               return "sv"
           else:
               return "unknown"

    property var_subtype:
        def __get__(self):
            if self.is_snp:
                if self.is_transition:
                    return "ts"
                if len(self.ALT) == 1:
                    return "tv"
                return "unknown"

            elif self.is_indel:
                if self.is_deletion:
                    return "del"
                if len(self.ALT) == 1:
                    return "ins"
                else:
                    return "unknown"

            svt = self.INFO.get("SVTYPE")
            if svt is None:
                return "unknown"
            if svt == "BND":
                return "complex"
            if self.INFO.get('IMPRECISE') is None:
                return svt
            return self.ALT[0].strip('<>')

    property start:
        def __get__(self):
            return self.b.pos

    property end:
        def __get__(self):
            return self.b.pos + self.b.rlen

    property ID:
        def __get__(self):
            cdef char *id = self.b.d.id
            if id == b".": return None
            return id

    property FILTER:
        def __get__(self):
            cdef int i
            cdef int n = self.b.d.n_flt
            if n == 1:
                if self.vcf.PASS != -1:
                    if self.b.d.flt[0] == self.vcf.PASS:
                        return None
                else:
                    v = bcf_hdr_int2id(self.vcf.hdr, BCF_DT_ID, self.b.d.flt[0])
                    if v == b"PASS":
                        self.vcf.PASS = self.b.d.flt[0]
                        return None
                    return v
            if n == 0:
                return None
            return ';'.join(bcf_hdr_int2id(self.vcf.hdr, BCF_DT_ID, self.b.d.flt[i]) for i in range(n))

        def __set__(self, filters):
            if isinstance(filters, basestring):
                filters = filters.split(";")
            cdef bcf_hdr_t *h = self.vcf.hdr
            cdef int *flt_ids = <int *>stdlib.malloc(sizeof(int) * len(filters))
            for i, fname in enumerate(filters):
                flt_ids[i] = bcf_hdr_id2int(h, BCF_DT_ID, fname)
            ret = bcf_update_filter(h, self.b, flt_ids, len(filters))
            stdlib.free(flt_ids)
            if ret != 0:
                raise Exception("not able to set filter: %s", filters)

    property QUAL:
        def __get__(self):
            cdef float q = self.b.qual
            if bcf_float_is_missing(q):
                return None
            return q

cdef inline HREC newHREC(bcf_hrec_t *hrec, bcf_hdr_t *hdr):
    cdef HREC h = HREC.__new__(HREC)
    h.hdr = hdr
    h.hrec = hrec
    return h

cdef class HREC(object):
    cdef bcf_hdr_t *hdr
    cdef bcf_hrec_t *hrec

    def __cinit__(HREC self):
        pass

    def __dealloc__(self):
        #bcf_hrec_destroy(self.hrec)
        self.hrec = NULL
        self.hdr = NULL

    @property
    def type(self):
        return ["FILTER", "INFO", "FORMAT", "CONTIG", "STR", "GENERIC"][self.hrec.type]

    def __getitem__(self, key):
        for i in range(self.hrec.nkeys):
            if self.hrec.keys[i] == key:
                return self.hrec.vals[i]
        raise KeyError

    def info(self, extra=False):
        """
        return a dict with commonly used stuffs
        """
        d = {}
        for k in ('Type', 'Number', 'ID', 'Description'):
            try:
                d[k] = self[k]
            except KeyError:
                continue
        d['HeaderType'] = self.type
        if extra:
            for i in range(self.hrec.nkeys):
                k = self.hrec.keys[i]
                if k in d: continue
                d[k] = self.hrec.vals[i]
        return d

    def __repr__(self):
        return str(self.info())

cdef class INFO(object):
    cdef bcf_hdr_t *hdr
    cdef bcf1_t *b
    cdef int _i

    def __cinit__(INFO self):
        self._i = 0

    def __setitem__(self, char *key, value):
        # only support strings for now.
        if value is True or value is False:

            ret = bcf_update_info_flag(self.hdr, self.b, key, b"", int(value))
            if ret != 0:
                raise Exception("not able to set flag", key, value, ret)
            return

        ret = bcf_update_info_string(self.hdr, self.b, key, str(value))
        if ret != 0:
            raise Exception("not able to set: %s -> %s (%d)", key, value, ret)

    cdef _getval(INFO self, bcf_info_t * info, char *key):

        if info.len == 1:
            if info.type == BCF_BT_INT8:
                if info.v1.i == INT8_MIN:
                    return None
                return <int>(info.v1.i)

            if info.type == BCF_BT_INT16:
                if info.v1.i == INT16_MIN:
                    return None
                return <int>(info.v1.i)

            if info.type == BCF_BT_INT32:
                if info.v1.i == INT32_MIN:
                    return None
                return <int>(info.v1.i)

            if info.type == BCF_BT_FLOAT:
                if bcf_float_is_missing(info.v1.f):
                    return None
                return info.v1.f

        if info.type == BCF_BT_CHAR:
            v = info.vptr[:info.vptr_len]
            if len(v) > 0 and v[0] == 0x7:
                return None
            return v

        return bcf_array_to_object(info.vptr, info.type, info.len)

    def __getitem__(self, okey):
        okey = str(okey).encode()
        cdef char *key = okey
        cdef bcf_info_t *info = bcf_get_info(self.hdr, self.b, key)
        if info == NULL:
            raise KeyError(key)
        return self._getval(info, key)

    def get(self, char *key, default=None):
        try:
            return self.__getitem__(key)
        except KeyError:
            return default

    def __iter__(self):
        self._i = 0
        return self

    def __next__(self):
        cdef bcf_info_t *info = NULL
        cdef char *name
        while info == NULL:
            if self._i >= self.b.n_info:
                raise StopIteration
            info = &(self.b.d.info[self._i])
            self._i += 1
        name = bcf_hdr_int2id(self.hdr, BCF_DT_ID, info.key)
        return name, self._getval(info, name)


# this function is copied verbatim from pysam/cbcf.pyx
cdef bcf_array_to_object(void *data, int type, int n, int scalar=0):
    cdef char    *datac
    cdef int8_t  *data8
    cdef int16_t *data16
    cdef int32_t *data32
    cdef float   *dataf
    cdef int      i

    if not data or n <= 0:
        return None

    if type == BCF_BT_CHAR:
        datac = <char *>data
        value = datac[:n] if datac[0] != bcf_str_missing else None
    else:
        value = []
        if type == BCF_BT_INT8:
            data8 = <int8_t *>data
            for i in range(n):
                if data8[i] == bcf_int8_vector_end:
                    break
                value.append(data8[i] if data8[i] != bcf_int8_missing else None)
        elif type == BCF_BT_INT16:
            data16 = <int16_t *>data
            for i in range(n):
                if data16[i] == bcf_int16_vector_end:
                    break
                value.append(data16[i] if data16[i] != bcf_int16_missing else None)
        elif type == BCF_BT_INT32:
            data32 = <int32_t *>data
            for i in range(n):
                if data32[i] == bcf_int32_vector_end:
                    break
                value.append(data32[i] if data32[i] != bcf_int32_missing else None)
        elif type == BCF_BT_FLOAT:
            dataf = <float *>data
            for i in range(n):
                if bcf_float_is_vector_end(dataf[i]):
                    break
                value.append(dataf[i] if not bcf_float_is_missing(dataf[i]) else None)
        else:
            raise TypeError('unsupported info type code')

        if not value:
            value = None
        elif scalar and len(value) == 1:
            value = value[0]
        else:
            value = tuple(value)

    return value

cdef inline Variant newVariant(bcf1_t *b, VCF vcf):
    cdef Variant v = Variant.__new__(Variant)
    v.b = b
    if not vcf.lazy:
        with nogil:
            bcf_unpack(v.b, 15)
    else:
        with nogil:
            bcf_unpack(v.b, 1|2|4)

    v.vcf = vcf
    v.POS = v.b.pos + 1
    cdef INFO i = INFO.__new__(INFO)
    i.b, i.hdr = b, vcf.hdr
    v.INFO = i
    return v

cdef class Writer(object):
    cdef htsFile *hts
    cdef bcf_hdr_t *hdr
    cdef public str name
    cdef bint header_written

    def __init__(self, fname, VCF tmpl):
        self.name = fname
        self.hts = hts_open(fname, "w")
        cdef bcf_hdr_t *h = tmpl.hdr
        cdef bcf_hdr_t *hdup = bcf_hdr_dup(h)
        self.hdr = hdup
        self.header_written = False

    def write_record(self, Variant var):
        if not self.header_written:
            bcf_hdr_write(self.hts, self.hdr)
            self.header_written = True
        return bcf_write(self.hts, self.hdr, var.b)

    def close(self):
        if self.hts != NULL:
            hts_close(self.hts)
            self.hts = NULL

    def __dealloc__(self):
        bcf_hdr_destroy(self.hdr)
        self.hdr = NULL
        self.close()
