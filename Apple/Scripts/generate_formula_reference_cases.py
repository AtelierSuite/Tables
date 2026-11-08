#!/usr/bin/env python3
"""Generate frozen formula oracles without importing or executing Tables.

Uses only Python's standard library: Decimal at 70 digits, exact Fraction
statistics and combinatorics, and datetime Gregorian dates. Run from anywhere:
  python3 Scripts/generate_formula_reference_cases.py

These vectors verify mathematical answers. Excel-specific coercion, errors,
references, arrays and documented approximations are tested separately.
"""
from decimal import Decimal as D, getcontext
from fractions import Fraction as F
from pathlib import Path
from datetime import date
from math import comb, factorial
import json
import cmath

getcontext().prec = 70
ROOT = Path(__file__).resolve().parents[1]
vectors = []
def add(name, arguments, answer, relative=2e-11):
    vectors.append((name, f'={name}({arguments})', float(answer), relative))
def decimal(value):
    if isinstance(value, F): return D(value.numerator) / D(value.denominator)
    return D(str(value))
def bessel(x, order, modified):
    x = D(x)
    return sum(((-1 if k % 2 and not modified else 1) * (x / 2) ** (2*k+order)
                / D(factorial(k)*factorial(k+order)) for k in range(100)), D(0))
def beta_cdf(x, a, b):
    n = a+b-1
    return sum((D(comb(n,j))*x**j*(1-x)**(n-j) for j in range(a,n+1)),D(0))
def bisect(function, target, low, high):
    for _ in range(230):
        mid = (low+high)/2
        if function(mid) < target: low=mid
        else: high=mid
    return (low+high)/2

# Exact/rational aggregate results at different signs, scales, and offsets.
for data in [[1,2,3],[-9,-2,0,5,11],[7,7,7,7],[1000000001,1000000002,1000000003],
             [F(1,1000),F(2,1000),F(4,1000)],list(range(-10,11))]:
    args='{'+','.join(str(decimal(x)) for x in data)+'}'
    mean=sum(map(F,data))/len(data)
    ss=sum((F(x)-mean)**2 for x in data)
    for name,result in [('SUM',sum(data)),('AVERAGE',mean),('DEVSQ',ss),('VAR.P',ss/len(data)),
                        ('VAR.S',ss/(len(data)-1)),('MIN',min(data)),('MAX',max(data))]:
        add(name,args,decimal(result))
    add('STDEV.P',args,decimal(ss/len(data)).sqrt())
    add('STDEV.S',args,decimal(ss/(len(data)-1)).sqrt())

# Binomial PMF and CDF, including tiny probabilities and endpoints.
for n in [1,5,20,100]:
    for probability in ['0','0.01','0.5','0.99','1']:
        p=D(probability)
        for k in sorted({0,1,n//2,n}):
            def pmf(j):
                left=D(1) if j==0 else p**j
                right=D(1) if n==j else (1-p)**(n-j)
                return D(comb(n,j))*left*right
            add('BINOM.DIST',f'{k},{n},{p},FALSE',pmf(k))
            add('BINOM.DIST',f'{k},{n},{p},TRUE',sum((pmf(j) for j in range(k+1)),D(0)))
for mean in ['0.1','1','5','30']:
    m=D(mean)
    for k in [0,1,5,20,50]:
        pmf=lambda j: (-m).exp()*m**j/D(factorial(j))
        add('POISSON.DIST',f'{k},{m},FALSE',pmf(k))
        add('POISSON.DIST',f'{k},{m},TRUE',sum((pmf(j) for j in range(k+1)),D(0)))

# Annuity closed forms, high precision and zero-rate cases. Both payment timings.
for rate in ['0','0.000001','0.01','0.2']:
    r=D(rate)
    for n in [1,12,120]:
        for timing in [0,1]:
            q=(1+r)**n
            annuity=D(n) if r==0 else (q-1)/r
            payment=-(D(1000)*q+D(50))/(annuity*(1+r*timing))
            add('PMT',f'{r},{n},1000,50,{timing}',payment)
            add('FV',f'{r},{n},-20,-1000,{timing}',D(1000)*q+D(20)*(1+r*timing)*annuity)
            add('PV',f'{r},{n},-20,50,{timing}',(D(20)*(1+r*timing)*annuity-D(50))/q)

# Audited replacements for inaccurate/truncated legacy answer constants.
add('BESSELI','1.5,1',bessel('1.5',1,True))
add('BESSELJ','1.9,2',bessel('1.9',2,False))
add('GEOMEAN','{4,5,8,7,11,4,3}',D(4*5*8*7*11*4*3)**(D(1)/7))
add('RRI','96,10000,11000',D('1.1')**(D(1)/96)-1)
flows=list(map(D,[-120000,39000,30000,21000,37000,46000]))
future=sum((x*D('1.12')**(5-i) for i,x in enumerate(flows) if x>0),D(0))
present=-sum((x/D('1.1')**i for i,x in enumerate(flows) if x<0),D(0))
add('MIRR','{-120000,39000,30000,21000,37000,46000},0.1,0.12',(future/present)**(D(1)/5)-1)
for name in ['BETA.INV','BETAINV']:
    add(name,'0.685470581,8,10,1,3',1+2*bisect(lambda p:beta_cdf(p,8,10),D('0.685470581'),D(0),D(1)))
# Duration: sixteen semiannual cash flows, coupon 4, redemption 100, yield .09.
weights=[D(4)/D('1.045')**k for k in range(1,17)]
weights[-1]+=D(100)/D('1.045')**16
add('DURATION','DATE(2008,1,1),DATE(2016,1,1),0.08,0.09,2,1',
    sum((D(k)*w/2 for k,w in enumerate(weights,1)),D(0))/sum(weights))
# XIRR: direct discounted cash-flow equation on independently counted actual days.
cash=list(map(D,[-10000,2750,4250,3250,2750]))
dates=[date(2008,1,1),date(2008,3,1),date(2008,10,30),date(2009,2,15),date(2009,4,1)]
times=[D((d-dates[0]).days)/365 for d in dates]
def discounted(r): return sum((v/(1+r)**t for v,t in zip(cash,times)),D(0))
add('XIRR','{-10000,2750,4250,3250,2750},{39448,39508,39751,39859,39904}',
    bisect(lambda r: -discounted(r),D(0),D('0'),D('1')))

# DB rounds its fixed declining-balance rate to three decimals.
r=(1-D('0.1')**(D(1)/6)).quantize(D('0.001'))
balance=D(1000000)*(1-r*D(7)/12)*(1-r)**5
add('DB','1000000,100000,6,7,7',balance*r*D(5)/12)
add('VDB','2400,300,10*12,6,18,1.5',D(2400)*((1-D('1.5')/120)**6-(1-D('1.5')/120)**18))
start=date(2018,7,1); end=date(2048,1,1)
year_days=D((date(2049,1,1)-date(2018,1,1)).days)/31
add('DISC','DATE(2018,7,1),DATE(2048,1,1),97.975,100,1',D('0.02025')*year_days/D((end-start).days))

header='''// Generated by Scripts/generate_formula_reference_cases.py. Do not edit.
// Oracles use 70-digit Decimal / exact Fraction and never run Tables.
import Foundation
@testable import Tables

let independentFormulaAnswerCases: [FormulaAnswerCase] = [
'''
lines=[f'    .init(function: "{n}", formula: {json.dumps(f)}, expected: .number({x!r}), relativeTolerance: {tol!r}),' for n,f,x,tol in vectors]
# Complex oracles use Python cmath, independent of Tables' complex implementation.
complex_operations = {
    'IMCOS': cmath.cos, 'IMCOSH': cmath.cosh, 'IMSIN': cmath.sin, 'IMSINH': cmath.sinh,
    'IMTAN': cmath.tan, 'IMCOT': lambda z: 1/cmath.tan(z),
    'IMCSC': lambda z: 1/cmath.sin(z), 'IMCSCH': lambda z: 1/cmath.sinh(z),
    'IMSEC': lambda z: 1/cmath.cos(z), 'IMSECH': lambda z: 1/cmath.cosh(z),
    'IMEXP': cmath.exp, 'IMLN': cmath.log, 'IMLOG10': cmath.log10,
    'IMLOG2': lambda z: cmath.log(z)/cmath.log(2), 'IMSQRT': cmath.sqrt,
}
for name, operation in complex_operations.items():
    for text, z in [('1+i',1+1j),('4+3i',4+3j),('-2+i',-2+1j)]:
        answer=operation(z)
        formula=f'={name}("{text}")'
        lines.append(f'    .init(function: "{name}", formula: {json.dumps(formula)}, expected: .text(""), absoluteTolerance: 1e-13, relativeTolerance: 2e-12, complexComponents: .init(real: {answer.real!r}, imaginary: {answer.imag!r})),')
(ROOT/'TablesTests/FormulaReferenceCases.swift').write_text(header+'\n'.join(lines)+'\n]\n')
print(f'Generated {len(lines)} independent reference vectors.')
for n,f,x,tol in vectors[-9:]: print(n,x)
