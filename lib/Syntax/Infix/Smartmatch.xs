#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#if PERL_VERSION_GE(5, 38, 0)
#include "XSParseInfix.h"
#endif

#ifndef cop_hints_fetch_pvn
#   define cop_hints_fetch_pvn(cop, key, len, hash, flags) Perl_refcounted_he_fetch(aTHX_ cop->cop_hints_hash, NULL, key, len, flags, hash)
#   define cop_hints_fetch_pvs(cop, key, flags) Perl_refcounted_he_fetch(aTHX_ cop->cop_hints_hash, NULL, STR_WITH_LEN(key), flags, 0)
#endif

#ifndef cop_hints_exists_pvn
#   if PERL_VERSION_GE(5, 16, 0)
#	   define cop_hints_exists_pvn(cop, key, len, hash, flags) cop_hints_fetch_pvn(cop, key, len, hash, flags | 0x02)
#   else
#	   define cop_hints_exists_pvn(cop, key, len, hash, flags) (cop_hints_fetch_pvn(cop, key, len, hash, flags) != &PL_sv_placeholder)
#   endif
#endif

#ifndef newSV_type_mortal
SV* S_newSV_type_mortal(pTHX_ svtype type) {
	SV* result = newSV(0);
	SvUPGRADE(result, type);
	return sv_2mortal(result);
}
#define newSV_type_mortal(type) S_newSV_type_mortal(aTHX_ type)
#endif

#ifndef OP_CHECK_MUTEX_LOCK
#define OP_CHECK_MUTEX_LOCK   NOOP
#define OP_CHECK_MUTEX_UNLOCK NOOP
#endif

#define pragma_base "Syntax::Infix::Smartmatch/"
#define pragma_name pragma_base "enabled"
#define pragma_name_length (sizeof(pragma_name) - 1)
static U32 pragma_hash;

#define smartermatch_enabled() cop_hints_exists_pvn(PL_curcop, pragma_name, pragma_name_length, pragma_hash, 0)

static Perl_ppaddr_t orig_smartmatch;

/* This version of do_smartmatch() implements an
   alternative table of matches.
 */
#define do_smartmatch(seen_this, seen_other) S_do_smartmatch(aTHX_ seen_this, seen_other)
STATIC OP * S_do_smartmatch(pTHX_ HV *seen_this, HV *seen_other) {
	dSP;

	SV *e = TOPs;	/* e is for 'expression' */
	SV *d = TOPm1s;	/* d is for 'default', as in PL_defgv */

	/* Take care only to invoke mg_get() once for each argument.
	 * Currently we do this by copying the SV if it's magical. */
	if (d) {
		if (SvGMAGICAL(d))
			d = sv_mortalcopy(d);
	}
	else
		d = &PL_sv_undef;

	assert(e);
	if (SvGMAGICAL(e))
		e = sv_mortalcopy(e);

	SP -= 2;	/* Pop the values */
	PUTBACK;

	/* ~~ undef */
	if (!SvOK(e)) {
		if (SvOK(d))
			RETPUSHNO;
		else
			RETPUSHYES;
	}
	else if (SvROK(e)) {
		/* First of all, handle overload magic of the rightmost argument */
		if (SvAMAGIC(e)) {
			SV * tmpsv;

			tmpsv = amagic_call(d, e, smart_amg, AMGf_noleft);
			if (tmpsv) {
				SPAGAIN;
				PUSHs(tmpsv);
				RETURN;
			}
		}

		/* ~~ qr// */
		if (SvTYPE(SvRV(e)) == SVt_REGEXP) {
			bool result;
			REGEXP* re = (REGEXP*)SvRV(e);
			PMOP* const matcher = cPMOPx(newPMOP(OP_MATCH, OPf_WANT_SCALAR | OPf_STACKED));
			PM_SETRE(matcher, ReREFCNT_inc(re));

			ENTER_with_name("matcher");
			SAVEFREEOP((OP *) matcher);
			SAVEOP();
			PL_op = (OP *) matcher;

			XPUSHs(d);
			PUTBACK;
			(void) PL_ppaddr[OP_MATCH](aTHX);
			SPAGAIN;
			result = SvTRUEx(POPs);
			PUSHs(result ? &PL_sv_yes : &PL_sv_no);

			LEAVE_with_name("matcher");
			RETURN;
		}
		/* Non-overloaded object */
		else if (SvOBJECT(SvRV(e))) {
			PUSHs(d == e ? &PL_sv_yes : &PL_sv_no);
		}
		/* ~~ sub */
		else if (SvTYPE(SvRV(e)) == SVt_PVCV) {
			I32 c;
			ENTER_with_name("smartmatch_array_elem_test");
			PUSHMARK(SP);
			PUSHs(d);
			PUTBACK;
			c = call_sv(e, G_SCALAR);
			SPAGAIN;
			if (c == 0)
				PUSHs(&PL_sv_no);
			LEAVE_with_name("smartmatch_array_elem_test");
			RETURN;
		}
		/* ~~ @array */
		else if (SvTYPE(SvRV(e)) == SVt_PVAV) {
			if (SvROK(d) && SvTYPE(SvRV(d)) == SVt_PVAV) {
				AV *other_av = MUTABLE_AV(SvRV(d));
				if (av_count(MUTABLE_AV(SvRV(e))) != av_count(other_av))
					RETPUSHNO;
				else {
					Size_t i;
					const Size_t other_len = av_count(other_av);

					if (seen_this == NULL)
						seen_this = (HV*)newSV_type_mortal(SVt_PVHV);
					if (seen_other == NULL)
						seen_other = (HV*)newSV_type_mortal(SVt_PVHV);

					for(i = 0; i < other_len; ++i) {
						SV * const * const this_elem = av_fetch(MUTABLE_AV(SvRV(e)), i, FALSE);
						SV * const * const other_elem = av_fetch(other_av, i, FALSE);

						if (!this_elem || !other_elem) {
							if ((this_elem && SvOK(*this_elem)) || (other_elem && SvOK(*other_elem)))
								RETPUSHNO;
						}
						else if (hv_exists_ent(seen_this, sv_2mortal(newSViv(PTR2IV(*this_elem))), 0) ||
								hv_exists_ent(seen_other, sv_2mortal(newSViv(PTR2IV(*other_elem))), 0)) {
							if (*this_elem != *other_elem)
								RETPUSHNO;
						}
						else {
							(void)hv_store_ent(seen_this, sv_2mortal(newSViv(PTR2IV(*this_elem))), &PL_sv_undef, 0);
							(void)hv_store_ent(seen_other, sv_2mortal(newSViv(PTR2IV(*other_elem))), &PL_sv_undef, 0);
							PUSHs(*other_elem);
							PUSHs(*this_elem);

							PUTBACK;
							(void) do_smartmatch(seen_this, seen_other);
							SPAGAIN;

							if (!SvTRUEx(POPs))
								RETPUSHNO;
						}
					}
					RETPUSHYES;
				}
			}
			else
				RETPUSHNO;
		}
	}
	/* ~~ scalar */
#if PERL_VERSION_GE(5, 36, 0)
	else if (SvIsBOOL(e)) {
		PUSHs(e);
		RETURN;
	}
#endif

	/* As a last resort, use string comparison */
	bool result = SvOK(d) && sv_eq_flags(d, e, 0);
	PUSHs(result ? &PL_sv_yes : &PL_sv_no);
	RETURN;
}

static OP* pp_smartermatch(pTHX) {
	if (smartermatch_enabled())
		return do_smartmatch(NULL, NULL);
	else
		return orig_smartmatch(aTHX);
}

#if PERL_VERSION_GE(5, 38, 0)
static const struct XSParseInfixHooks hooks_smarter = {
	.cls            = XPI_CLS_MATCH_MISC,
	.permit_hintkey = "Syntax::Infix::Smartmatch/enabled",
	.ppaddr         = &pp_smartermatch,
};
#endif

static unsigned initialized;

MODULE = Syntax::Infix::Smartmatch				PACKAGE = Syntax::Infix::Smartmatch

PROTOTYPES: DISABLED

BOOT:
	OP_CHECK_MUTEX_LOCK;
	if (!initialized) {
		initialized = 1;
		orig_smartmatch = PL_ppaddr[OP_SMARTMATCH];
		PL_ppaddr[OP_SMARTMATCH] = pp_smartermatch;
	}
	OP_CHECK_MUTEX_UNLOCK;
#	if PERL_VERSION_GE(5, 38, 0)
	boot_xs_parse_infix(0.26);
	register_xs_parse_infix("~~", &hooks_smarter, NULL);
#	endif
