/* =====================================================================================================
   ZARA GLOBAL RETAIL ANALYTICS CAPSTONE  |  PROBLEM STATEMENT 2: PRICING, PROMOTIONS AND MARGIN
   Author        : Yatharth Aphale
   Business owner: Head of Merchandising
   Database      : MySQL 8.x  (window functions, CTEs and STR_TO_DATE are used)
   Tables used   : transactions, products, discounts, stores, employees
                   + helper tables exchange_rates and country_map (see SETUP below)
   Period        : 1 Jan 2023 - 18 Mar 2025 (3,340,935 invoice lines)

   HOW TO RUN    : Load the six CSVs into MySQL first (csv_to_mysql.py), create the two helper tables
                   below, then run this file top to bottom. Every query has its own comment block.

   DATA-HANDLING RULES USED IN EVERY QUERY
   1. Money  : always SUM(Line_Total). Invoice_Total repeats on every line of an invoice, so summing
               it would double count (and Section 1 shows it is also wrong on some invoices).
   2. Returns: a return is its own RET- invoice with a NEGATIVE Line_Total and a POSITIVE Quantity.
               So Net sales = SUM(Line_Total) (returns reduce it automatically), and a returned unit
               must be counted as -Quantity whenever units or cost are netted:
               IF(Transaction_Type = 'Return', -Quantity, Quantity).
   3. Currency: every amount is converted to US dollars with exchange_rates
               (1 EUR = 1.08 USD, 1 GBP = 1.27 USD, 1 CNY = 0.14 USD, USD = 1).
   4. Cost   : Production_Cost is stored in EUR, so cost in USD = Quantity x Production_Cost x 1.08.
   5. Gross margin = Net sales (USD) - Production cost (USD) x Quantity.
   6. Partial year: 2025 stops on 18 March, so 2025 is only ever compared with the same dates of 2024.
   ===================================================================================================== */

/* -----------------------------------------------------------------------------------------------------
   SETUP (run once if the helper tables do not exist yet - shown for completeness, kept commented out)
   -----------------------------------------------------------------------------------------------------
   CREATE TABLE exchange_rates (currency CHAR(3) PRIMARY KEY, usd_rate DECIMAL(8,4));
   INSERT INTO exchange_rates VALUES ('USD',1.00),('EUR',1.08),('GBP',1.27),('CNY',0.14);

   -- country_map translates local-language country names found in stores.Country to English
   -- (e.g. Deutschland -> Germany, Espana -> Spain, the Chinese name for China -> China)
   CREATE TABLE country_map (raw_name VARCHAR(100) PRIMARY KEY, english VARCHAR(100));
   ----------------------------------------------------------------------------------------------------- */


-- =====================================================================================================
-- SECTION 1: DATA CHECKS  ("Trust the numbers")
-- Goal: test whether the data can be trusted before any KPI is reported, and record what to do about each issue.
-- =====================================================================================================

-- Data checks 

-- 1. Trust the numbers. Find invoices whose Invoice Total does not equal the sum of their line totals, 
--    lines with no size or colour, products whose production cost cannot be right, sales served by an employee from another store,
--    and products that were never sold. Record what you would do about each. 

-- ---- Check 1a: Invoice Total does not equal the sum of the line totals --------------------------------
-- Question : Does Invoice_Total always equal SUM(Line_Total) for its invoice?
-- Logic    : Group lines by Invoice_ID, compare MAX(Invoice_Total) (it repeats on each line) with SUM(Line_Total),
--            and keep invoices that differ by more than 1 cent (tolerance for rounding).
-- Result   : Many invoices fail the test. The gap is not rounding: Invoice_Total is exactly 1.5x, 1.1x or 0.9x
--            the line sum (e.g. INV-CN-001-03000047: 1,724.55 vs 1,149.70 = x1.5; INV-FR-001-03000110:
--            36.50 vs 40.56 = x0.9). This looks like a systematic header error, not a data-entry slip.
-- Action   : (1) Never use Invoice_Total for sales; every KPI in this file uses SUM(Line_Total).
--            (2) Send the invoice list to Finance for reconciliation against the POS ledger.
--            (3) Add an automatic Invoice_Total = SUM(Line_Total) validation to the data load.

-- Invoice Total Mismatch
SELECT 
    Invoice_ID,
    MAX(Invoice_Total) AS Invoice_Total,
    Round(SUM(Line_Total),2) AS Calculated_Line_Total,
    Round(MAX(Invoice_Total) - SUM(Line_Total),2) AS Difference
FROM
    transactions
GROUP BY Invoice_ID
HAVING ABS(MAX(Invoice_Total) - SUM(Line_Total)) > 0.01;

-- ---- Check 1b: Lines with no size or colour ------------------------------------------------------------
-- Question : How many invoice lines are missing Size and/or Color?
-- Logic    : COUNT(*) - COUNT(col) gives the number of NULLs in that column; SUM(boolean) counts lines
--            where BOTH are NULL.
-- Result   : 3,340,935 lines in total; 13,363 have no Size (0.40%), 6,681 have no Color (0.20%) and
--            27 have neither.
-- Action   : Keep the lines in every sales and margin figure (the revenue is valid). Exclude them only from
--            size- or colour-level analysis (e.g. the size return-rate table in Query 11, where they appear
--            as NULL). Make Size and Color mandatory fields at the till.

-- Missing Size and Color
SELECT
    COUNT(*) AS Total_Transactions,
    COUNT(*) - COUNT(Size) AS Missing_Size,
    COUNT(*) - COUNT(Color) AS Missing_Color,
    SUM(Size IS NULL AND Color IS NULL) AS Missing_Both
FROM transactions;

-- ---- Check 1c: Production cost that cannot be right ---------------------------------------------------
-- Question : Are there products whose Production_Cost is missing, zero or negative?
-- Logic    : Simple filter on products for NULL or <= 0 cost.
-- Result   : 0 rows - no NULL, zero or negative costs.
-- Note     : This test cannot catch costs that are positive but implausibly HIGH. The very negative margin of
--            Woman > Jackets in Query 3 (-64.7%) suggests some products carry inflated costs, so review
--            cost per product against its sub-category average before reporting margins externally.
-- Action   : Cap or correct implausible costs once confirmed with Merchandising, and document the rule.

-- Production Cost cannot be right
SELECT
    Product_ID,
    Category,
    Sub_Category,
    Description_EN,
    Production_Cost
FROM products
WHERE Production_Cost IS NULL
   OR Production_Cost <= 0;
   
-- ---- Check 1d: Sales served by an employee from another store -----------------------------------------
-- Question : Is the employee recorded on an invoice always an employee of the store where the sale happened?
-- Logic    : Join transactions to employees on Employee_ID and keep rows where the transaction Store_ID is
--            different from the employee's home Store_ID.
-- Result   : Mismatches exist, on both sale and return invoices (e.g. employee 961, home store 20, serving in
--            store 21; employee 1635, home store 32, serving in store 2).
-- Action   : Keep the sales (the revenue is real) and report them by the TRANSACTION store. For
--            sales-per-employee and sales-per-associate comparisons, either exclude these invoices or
--            attribute them to the store where they occurred, and state which rule was used.
--            Ask HR whether these are loans / cover shifts or ID errors.

-- Employee Store Mismatch 
SELECT
    t.Invoice_ID,
    t.Employee_ID,
    t.Store_ID AS Transaction_Store,
    e.Store_ID AS Employee_Store,
    e.Name AS Employee_Name
FROM transactions t
INNER JOIN employees e
   USING (Employee_ID)
WHERE t.Store_ID <> e.Store_ID;

-- ---- Check 1e: Products that were never sold ---------------------------------------------------------
-- Question : Which catalogue products have no sale line at all?
-- Logic    : LEFT JOIN products to Sale lines and keep products with no match (anti-join).
-- Result   : A list of products with zero sales. Most were launched in July 2022 (before the data window, so
--            likely old stock), and some launched very late (e.g. product 977, Perfume, launched 17 Feb 2025,
--            one month before the data ends).
-- Action   : Do not treat as errors. Classify as (a) dead / slow stock for Merchandising to clear or stop
--            re-ordering, and (b) late launches that have not had time to sell. Exclude them from
--            product-level ranking logic.

-- Products Never Sold
SELECT
    p.Product_ID,
    p.Category,
    p.Sub_Category,
    p.Description_EN,
    p.Production_Cost,
    p.Launch_Date
FROM products p
LEFT JOIN transactions t
    ON p.Product_ID = t.Product_ID
    AND t.Transaction_Type = 'Sale'
WHERE t.Product_ID IS NULL;


-- =====================================================================================================
-- SECTION 2: SALES AND MARGIN
-- =====================================================================================================

-- Sales and margin 

-- 2. KPIs. By year: gross sales, returns, net sales, gross margin and gross margin %.   

-- ---- Query 2a: Yearly gross sales, returns and net sales (USD) --------------------------------------
-- Question : What are gross sales, returns and net sales by year?
-- Logic    : Convert Line_Total to USD through exchange_rates. Gross = Sale lines only; Returns = absolute value
--            of Return lines; Net = all lines (returns already negative), so Net = Gross - Returns.
-- Result   : 2023: gross $64.16M, returns $6.67M, net $57.49M.   2024: gross $65.57M, returns $7.35M,
--            net $58.22M (+1.3% vs 2023).   2025 (1 Jan-18 Mar only): net $10.87M.
--            Returns rose from 10.4% to 11.2% of gross sales between 2023 and 2024.
-- Takeaway : Growth is almost flat (+1.3%) and returns are growing faster than sales. 2025 is a partial year
--            and must not be compared with a full year.

-- Gross Sales, Returns and Net Sales
SELECT
    YEAR(t.Date) AS Year,

    ROUND(SUM(IF(t.Transaction_Type = 'Sale',
        t.Line_Total * fx.usd_rate, 0)), 2) AS Gross_Sales,

    ABS(ROUND(SUM(IF(t.Transaction_Type = 'Return',
        t.Line_Total * fx.usd_rate, 0)), 2)) AS Returns,

    ROUND(SUM(t.Line_Total * fx.usd_rate), 2) AS Net_Sales

FROM transactions as t

JOIN exchange_rates as fx
    ON t.Currency = fx.Currency

GROUP BY YEAR(t.Date)
ORDER BY Year;

-- ---- Query 2b: Yearly gross margin and gross margin % (USD) ----------------------------------------
-- Question : How much margin is earned each year?
-- Logic    : Margin = Net sales USD - (Quantity x Production_Cost x 1.08). Returned units are made negative so
--            their cost is added back. Margin % = margin / net sales.
-- Result   : 2023: $27.25M (47.40%).   2024: $26.99M (46.36%).   2025 YTD: $4.76M (43.77%).
-- Takeaway : Net sales grew +1.3% in 2024 but gross margin fell by $0.26M and by about 1 point of margin %,
--            and is lower again in early 2025: more sales are coming through at a lower margin.

-- Gross Margin & Gross Margin %
SELECT 
    YEAR(t.Date) AS Year,
    ROUND(SUM((t.Line_Total * fx.usd_rate) - (IF(t.Transaction_Type = 'Return',
                - t.Quantity,
                t.Quantity) * p.Production_Cost * 1.08)),
            2) AS Gross_Margin_USD,
    ROUND(SUM((t.Line_Total * fx.usd_rate) - (IF(t.Transaction_Type = 'Return',
                - t.Quantity,
                t.Quantity) * p.Production_Cost * 1.08)) / NULLIF(SUM(t.Line_Total * fx.usd_rate), 0) * 100,
            2) AS Gross_Margin_Percentage
FROM
    transactions t
        JOIN
    products p ON t.Product_ID = p.Product_ID
        JOIN
    exchange_rates fx ON t.Currency = fx.Currency
GROUP BY YEAR(t.Date)
ORDER BY Year;


-- ---- Query 3: Gross margin % by category and sub-category ----------------------------------------------
-- Question : Which sub-categories earn the least, and why?
-- Logic    : Same margin formula as Query 2b, grouped by Category and Sub_Category and sorted from lowest
--            margin % upwards.
-- Result   : Lowest: Woman Jackets -64.74% (margin -$3.37M on $5.21M sales), then Woman Shirts and Blouses
--            37.05%, Kids Girls 37.87%, Woman Tops and Bodysuits 42.21%, Woman Coats and Trench Coats
--            44.03%. Highest: Woman T-Shirts 57.92%, Man T-Shirts and Polos 57.05%.
-- Why      : Two drivers appear. Heavy markdown (Kids Girls: 26.1% of units sold on markdown, Query 5a) and a
--            thin price-to-cost structure (Woman Shirts and Blouses has an average markdown share of 18.4% yet
--            only 37% margin). The negative Woman Jackets margin is far outside the range of every other
--            sub-category and is probably caused by a few inflated production costs (see the note in
--            Check 1c) - verify before acting on it.

-- 3. Category margin. Gross margin % by category (Woman, Man, Kids) and sub-category. Which sub-categories earn least, and why?  

SELECT 
    p.Category,
    p.Sub_Category,
    ROUND(SUM(t.Line_Total * fx.usd_rate), 2) AS Net_Sales_USD,
    ROUND(SUM((t.Line_Total * fx.usd_rate) - (IF(t.Transaction_Type = 'Return',
                - t.Quantity,
                t.Quantity) * p.Production_Cost * 1.08)),
            2) AS Gross_Margin_USD,
    ROUND(SUM((t.Line_Total * fx.usd_rate) - (IF(t.Transaction_Type = 'Return',
                - t.Quantity,
                t.Quantity) * p.Production_Cost * 1.08)) / NULLIF(SUM(t.Line_Total * fx.usd_rate), 0) * 100,
            2) AS Gross_Margin_Percentage
FROM
    transactions t
        JOIN
    products p ON t.Product_ID = p.Product_ID
        JOIN
    exchange_rates fx ON t.Currency = fx.Currency
GROUP BY p.Category , p.Sub_Category
ORDER BY Gross_Margin_Percentage ASC;


-- 4. Markdown depth. Group sale lines into bands with CASE (full price, 30%, 40–50%, 60–70%). 
--    Show each band's share of lines, net sales and gross margin %. At which depth does Zara start losing money on a sale? 
-- ---- Query 4 explained --------------------------------------------------------------------------------
-- Logic    : CASE groups every Sale line into a depth band from t.Discount (0, 0.3, 0.4-0.5, 0.6-0.7). Lines per
--            band, net sales and margin % are computed per band. Only Sale lines are used, so quantity needs
--            no return sign.
-- Result   : Full price 2,445,540 lines (80.4% of sale lines), net $123.74M, margin 50.00%.
--            30%: 181,154 lines (6.0%), $6.78M, 36.88%.     40-50%: 373,075 lines (12.3%), $10.87M, 21.22%.
--            60-70%: 42,793 lines (1.4%), $0.64M, -47.51%.
-- Takeaway : Zara still earns about 21% margin at 40-50% off, but loses money once markdowns reach 60-70%
--            (-47.5%). The break-even depth lies between 50% and 60%, so 50% should be the maximum depth.
--            About one sale line in five is sold on markdown, but those lines are only ~13% of net sales.


SELECT 
    CASE
        WHEN t.Discount = 0 THEN 'Full Price'
        WHEN t.Discount = 0.3 THEN '30%'
        WHEN t.Discount IN (0.4 , 0.5) THEN '40-50%'
        WHEN t.Discount IN (0.6 , 0.7) THEN '60-70%'
    END AS Discount_Band,
    
    COUNT(*) AS Total_Lines,
    
    ROUND(SUM(t.Line_Total * fx.usd_rate), 2) AS Net_Sales_USD,
    
    ROUND(SUM((t.Line_Total * fx.usd_rate) - (t.Quantity * p.Production_Cost * 1.08)),2) 
    AS Gross_Margin_USD,
    
    ROUND(SUM((t.Line_Total * fx.usd_rate) - (t.Quantity * p.Production_Cost * 1.08)) / NULLIF(SUM(t.Line_Total * fx.usd_rate), 0) * 100,2)
    AS Gross_Margin_Percentage
FROM
    transactions t
        JOIN
    products p ON t.Product_ID = p.Product_ID
        JOIN
    exchange_rates fx ON t.Currency = fx.Currency
WHERE
    t.Transaction_Type = 'Sale'
GROUP BY Discount_Band
ORDER BY CASE Discount_Band
    WHEN 'Full Price' THEN 1
    WHEN '30%' THEN 2
    WHEN '40-50%' THEN 3
    WHEN '60-70%' THEN 4
END;

-- ---- Query 5a: Share of each sub-category's units sold on markdown ------------------------------------
-- Question : Which sub-categories end up in the sale most often (overbought collections)?
-- Logic    : Per sub-category: total units (Sale lines), units with Discount > 0, and the percentage. Sorted
--            by markdown share, highest first.
-- Result   : Most marked-down: Man Coats and Jackets 29.09%, Man Knitwear and Sweatshirts 28.49%, Kids Kids
--            Shoes 27.06%, Kids Girls 26.12%, Man Shoes 25.29%, Woman Knitwear 25.04%, Kids Boys 25.04%.
--            Least marked-down among those shown: Man Blazers and Suits 17.70%, Man Trousers and Shorts 17.83%.
-- Takeaway : Winter-weight items (coats, knitwear) and kids' lines are the overbought collections: a quarter
--            or more of their units leave at a discount.

-- 5. What ends up in the sale. What share of each sub-category's units is sold on markdown? Which collections are overbought, and which are never discounted? 

SELECT 
    p.Category,
    p.Sub_Category,
   
   SUM(t.Quantity) AS Total_Units_Sold,
   
   SUM(IF(t.Discount > 0, t.Quantity, 0)) AS Markdown_Units,
   
   ROUND(SUM(IF(t.Discount > 0, t.Quantity, 0)) / NULLIF(SUM(t.Quantity), 0) * 100,
            2) AS Markdown_Units_Percentage,
    
    SUM(IF(t.Discount = 0, t.Quantity, 0)) AS Full_Price_Units

FROM
    transactions t
        JOIN
    products p ON t.Product_ID = p.Product_ID
WHERE
    t.Transaction_Type = 'Sale'
GROUP BY p.Category , p.Sub_Category
ORDER BY Markdown_Units_Percentage DESC;

-- ---- Query 5b: Sub-categories that are never discounted ---------------------------------------------
-- Logic    : HAVING MAX(Discount) = 0 keeps sub-categories that have not had a single discounted sale line.
-- Result   : Man Perfumes (35,612 units) and Woman Perfumes (76,640 units) - Zara never marks perfumes down.
-- Takeaway : Perfumes prove that a category can sell without sale pricing; use them as the full-price benchmark.

SELECT 
    p.Category,
    p.Sub_Category,
    SUM(t.Quantity) AS Total_Units_Sold
FROM
    transactions t
        JOIN
    products p ON t.Product_ID = p.Product_ID
WHERE
    t.Transaction_Type = 'Sale'
GROUP BY p.Category , p.Sub_Category
HAVING MAX(t.Discount) = 0;


-- =====================================================================================================
-- SECTION 3: PROMOTIONS
-- =====================================================================================================

-- Promotions 

-- ---- Query 6: Sale phases vs the two weeks before each phase -----------------------------------------
-- Question : Which sale phases are worth their margin?
-- Method   : The discounts table is the markdown calendar (one row per phase x category x sub-category x
--            country list). The query is built as seven steps (CTEs):
--            STEP 1  cal          : read the calendar, convert Start/End text dates to DATE, ignore blanks.
--            STEP 2  phase_scope  : expand each phase to the countries it applies to (blank = all countries;
--                                   otherwise the comma-separated list is matched with FIND_IN_SET).
--            STEP 3  win          : find the first and last date needed, including the 14 days before the
--                                   first phase, so transactions are scanned only once.
--            STEP 4  daily        : aggregate transactions by day, country, category and sub-category into
--                                   units, net sales USD and cost USD (returns negative).
--            STEP 5  phase_window : join each phase to the days inside it and to the 14 days before it,
--                                   matching on date range + category + sub-category + country.
--            STEP 6  agg          : sum units, sales and margin for the phase days and for the 14 baseline days.
--            STEP 7  final SELECT : per-day change in units and sales vs the baseline, margin % in the phase
--                                   vs the baseline, and margin dollars per day gained or lost.
--            Phase length is capped at 18 Mar 2025 (end of data). Comparisons are per day so phases of
--            different length are comparable.
-- Result   : * The FIRST phase of each season at 30% (Summer 2023 +80.6% units/day, Summer 2024 +78.9%, Winter
--              2023 +46.9%) lifts units and sales and still adds margin dollars per day (+$11,954, +$6,130,
--              +$1,140).
--            * 40% opening phases add volume (+40% to +89% units/day) but dilute margin (e.g. 57% -> 33%) and
--              lose margin dollars (-$2,110, -$3,550 and -$14,857/day).
--            * Later phases (second 40%, 50%) fall BELOW the pre-sale baseline in units and sales and lose
--              margin dollars every time (from -$2.6K to -$35.1K per day).
--            * Exception: the 30% phase of the Dec 2024 Winter Sale in France/Portugal lost $2,144/day (it
--              starts right after the Christmas peak).
--            * 60-70% phases run at negative margin (-8.3% to -19.2%).
--            * Black Friday 2024 (US and UK, 4 days): units/day +260.6%, sales +177.7%, margin 44.7% vs 48.2%
--              before, +$42,321 margin per day. Early Winter Sale (20 Dec 2024, US/UK): 30% phase +108.6%
--              units and +$5,664/day; 40% phase +102.2% units but -$2,043/day.
-- Takeaway : Only the first, shallow (30%) phase of a sale pays for itself. Deeper, later phases clear stock
--            at a loss. Black Friday paid off for margin dollars in its short window.
-- Caveat   : The baseline of later phases is the previous (already discounted) phase, so their change is
--            partly "sale fatigue"; the first phase of each season is the cleanest comparison.

-- 6. Sale phases. Join transactions to the discounts calendar on date range, category, sub-category and country.
-- For each sale season and phase, compare units, net sales and margin with the two weeks before the sale started. 
-- Which phases are worth their margin? 

WITH

-- STEP 1: Prepare sale phase calendar
cal AS (
    SELECT DISTINCT
        Description AS phase,
        STR_TO_DATE(Start, '%d-%m-%Y') AS start_date,
        STR_TO_DATE(End, '%d-%m-%Y') AS end_date,
        Category AS category,
        Sub_Category AS sub_category,
        NULLIF(TRIM(Country), '') AS discount_country
    FROM discounts
    WHERE STR_TO_DATE(Start, '%d-%m-%Y') >= '2023-01-15'
      AND STR_TO_DATE(Start, '%d-%m-%Y') <= '2025-03-18'
),

-- STEP 2: Expand each phase to its applicable countries
phase_scope AS (
    SELECT DISTINCT
        c.phase,
        c.start_date,
        c.end_date,
        c.category,
        c.sub_category,
        cl.country
    FROM cal c
    CROSS JOIN (
        SELECT DISTINCT
            COALESCE(cm.english, s.Country) AS country
        FROM stores s
        LEFT JOIN country_map cm
            ON s.Country = cm.raw_name
    ) cl
    WHERE c.discount_country IS NULL
       OR FIND_IN_SET(
            cl.country,
            REPLACE(c.discount_country, ', ', ',')
       ) > 0
),

-- STEP 3: Determine required transaction date range
win AS (
    SELECT
        MIN(start_date) - INTERVAL 14 DAY AS w_from,
        MAX(LEAST(end_date, '2025-03-18')) + INTERVAL 1 DAY AS w_to
    FROM phase_scope
),

-- STEP 4: Aggregate transactions by day, country and sub-category
daily AS (
    SELECT
        DATE(t.Date) AS sale_date,
        COALESCE(cm.english, s.Country) AS country,
        p.Category AS category,
        p.Sub_Category AS sub_category,

        SUM(
            CASE
                WHEN t.Transaction_Type = 'Return'
                    THEN -ABS(CAST(t.Quantity AS DECIMAL(18,4)))
                ELSE CAST(t.Quantity AS DECIMAL(18,4))
            END
        ) AS units,

        SUM(
            CAST(t.Line_Total AS DECIMAL(18,4)) * er.usd_rate
        ) AS net_usd,

        SUM(
            CASE
                WHEN t.Transaction_Type = 'Return'
                    THEN -ABS(CAST(t.Quantity AS DECIMAL(18,4)))
                ELSE CAST(t.Quantity AS DECIMAL(18,4))
            END
            * CAST(p.Production_Cost AS DECIMAL(18,4))
            * 1.08
        ) AS cost_usd

    FROM win w

    STRAIGHT_JOIN transactions t
        ON t.Date >= CONCAT(DATE_FORMAT(w.w_from, '%Y-%m-%d'), ' 00:00:00')
       AND t.Date < CONCAT(DATE_FORMAT(w.w_to, '%Y-%m-%d'), ' 00:00:00')

    JOIN products p
        ON p.Product_ID = t.Product_ID

    JOIN stores s
        ON s.Store_ID = t.Store_ID

    LEFT JOIN country_map cm
        ON s.Country = cm.raw_name

    JOIN exchange_rates er
        ON er.currency = t.Currency

    GROUP BY
        DATE(t.Date),
        COALESCE(cm.english, s.Country),
        p.Category,
        p.Sub_Category
),

-- STEP 5: Match phase transactions and preceding 14 days
phase_window AS (
    SELECT
        ps.phase,
        ps.start_date,
        ps.end_date,
        ps.country,
        d.sale_date,
        d.units,
        d.net_usd,
        d.cost_usd

    FROM phase_scope ps

    JOIN daily d
        ON d.category = ps.category
       AND d.sub_category = ps.sub_category
       AND d.country = ps.country

       AND d.sale_date BETWEEN
           ps.start_date - INTERVAL 14 DAY
           AND LEAST(ps.end_date, '2025-03-18')
),

-- STEP 6: Aggregate phase and baseline performance
agg AS (
    SELECT
        phase,
        start_date,

        MAX(LEAST(end_date, '2025-03-18')) AS end_cap,

        GROUP_CONCAT(
            DISTINCT country
            ORDER BY country
            SEPARATOR ', '
        ) AS countries,

        SUM(
            CASE WHEN sale_date >= start_date
                THEN units ELSE 0
            END
        ) AS units_phase,

        SUM(
            CASE WHEN sale_date < start_date
                THEN units ELSE 0
            END
        ) AS units_before,

        SUM(
            CASE WHEN sale_date >= start_date
                THEN net_usd ELSE 0
            END
        ) AS sales_phase,

        SUM(
            CASE WHEN sale_date < start_date
                THEN net_usd ELSE 0
            END
        ) AS sales_before,

        SUM(
            CASE WHEN sale_date >= start_date
                THEN net_usd - cost_usd ELSE 0
            END
        ) AS margin_phase,

        SUM(
            CASE WHEN sale_date < start_date
                THEN net_usd - cost_usd ELSE 0
            END
        ) AS margin_before

    FROM phase_window

    GROUP BY
        phase,
        start_date
)

-- STEP 7: Final Sale Phase Analysis
SELECT
    phase,
    start_date,
    countries,

    DATEDIFF(end_cap, start_date) + 1 AS phase_days,

    ROUND(
        100 * (
            (units_phase / (DATEDIFF(end_cap, start_date) + 1))
            / NULLIF(units_before / 14, 0) - 1
        ), 1
    ) AS units_per_day_change_pct,

    ROUND(
        100 * (
            (sales_phase / (DATEDIFF(end_cap, start_date) + 1))
            / NULLIF(sales_before / 14, 0) - 1
        ), 1
    ) AS sales_per_day_change_pct,

    ROUND(
        100 * margin_phase / NULLIF(sales_phase, 0),
        1
    ) AS margin_pct_phase,

    ROUND(
        100 * margin_before / NULLIF(sales_before, 0),
        1
    ) AS margin_pct_before,

    ROUND(
        (margin_phase / (DATEDIFF(end_cap, start_date) + 1))
        - (margin_before / 14),
        0
    ) AS margin_usd_per_day_change

FROM agg

ORDER BY
    start_date,
    phase;
-- ---- Query 7: Black Friday / early Winter Sale 2024 - full-price sales before Christmas --------------
-- Question : Did the 2024 events (US and UK only) add sales or just pull them forward at a lower price?
-- Logic    : Take FULL-PRICE Sale lines (Discount = 0) for 4-24 December (the three weeks before Christmas) in
--            2023 and 2024. Split markets into US and UK (events ran) vs Other countries (no events = control
--            group). COUNT(DISTINCT Invoice_ID) counts invoices once.
-- Result   : US and UK full-price net sales fell from $1,411,400 (2023) to $1,250,476 (2024) = -11.4%; units
--            -11.7% (28,193 -> 24,898); invoices -5.6% (14,039 -> 13,251).
--            Other countries rose from $3,531,506 to $3,658,229 = +3.6%; units +1.7%; invoices +1.3%.
-- Takeaway : Where there was no event, full-price December sales grew. Where the events ran they fell, a gap
--            of about 15 points. The events moved demand earlier at a lower price (cannibalised full-price
--            sales) rather than creating all-new demand.

-- 7. Black Friday and the early sale. Black Friday 2024 and the early Winter Sale ran only in the US and UK. 
-- Compare full-price sales in the three weeks before Christmas 2024 with 2023, for the US and UK and for the other countries.
-- Did the events add sales or move them earlier at a lower price? 

SELECT 
    YEAR(t.Date) AS Sales_Year,
    IF(s.Country IN ('United States' , 'United Kingdom'),
        'US & UK',
        'Other Countries') AS Market,
   
   COUNT(DISTINCT t.Invoice_ID) AS Total_Invoices,
   
   SUM(t.Quantity) AS Total_Units,
   
   ROUND(SUM(t.Line_Total * fx.usd_rate), 2) AS Full_Price_Net_Sales

FROM
    transactions t
        JOIN
    stores s ON s.Store_ID = t.Store_ID
        JOIN
    exchange_rates fx ON fx.Currency = t.Currency
WHERE
    t.Transaction_Type = 'Sale'
      
      AND t.Discount = 0
      
      AND ((t.Date >= '2023-12-04'
      
      AND t.Date < '2023-12-25')
      
      OR (t.Date >= '2024-12-04'
      
      AND t.Date < '2024-12-25'))

GROUP BY YEAR(t.Date) , Market

ORDER BY Sales_Year , Market;


-- ---- Query 8: Monthly trend with month-on-month and year-on-year change --------------------------------
-- Question : How do net sales and margin move month by month, and how much of each peak came from markdowns?
-- Logic    : CTE 1 builds monthly net sales, gross margin and net sales on lines with Discount > 0.
--            CTE 2 uses LAG(...,1) for the previous month and LAG(...,12) for the same month a year earlier
--            (valid because every month is present, so 12 rows back = 12 months back).
--            Final SELECT turns them into % changes and the markdown share of net sales.
-- Result   : Markdown share peaks in the sale months: Jan 49.6% (2023) and 58.9% (2024), Jul 54.2% (2023)
--            and 52.8% (2024); Dec 2023 is 15.1% (the Winter Sale starts 26 Dec). Full-price months
--            (Mar-May, Sep-Nov) have about 0% markdown.
--            Margin % follows the same pattern: Jan 2024 33% and Jul 2024 35% vs Sep 2024 52%, Oct 2024 49%.
--            Jan 2024 sales were -16.0% YoY and margin -19.6% YoY; Jul 2024 sales -8.7% and margin -24.2%.
-- Takeaway : Half of January and July sales come from markdown lines, and those months are down year on
--            year with an even bigger fall in margin. The Dec peak is mostly full price.
-- Note     : Small negative markdown shares (e.g. -0.07% in Mar 2023) are returns of earlier markdown lines.

-- 8. Monthly trend. Net sales and margin by month with LAG() for month-on-month and year-on-year change. 
-- How much of each peak month came from marked-down lines? 

WITH Monthly_Summary AS
(
    SELECT
        DATE_FORMAT(t.Date, '%Y-%m') AS Sales_Month,

        ROUND(
            SUM(t.Line_Total * fx.usd_rate), 2
        ) AS Net_Sales,

        ROUND(
            SUM(
                (t.Line_Total * fx.usd_rate)
                -
                (
                    IF(t.Transaction_Type = 'Return',
                       -t.Quantity, t.Quantity)
                    * p.Production_Cost * 1.08
                )
            ), 2
        ) AS Gross_Margin,

        ROUND(SUM(IF(t.Discount > 0,
                t.Line_Total * fx.usd_rate, 0)), 2) 
                AS Markdown_Net_Sales

    FROM transactions t

    JOIN products p
        ON p.Product_ID = t.Product_ID

    JOIN exchange_rates fx
        ON fx.Currency = t.Currency

    GROUP BY
        DATE_FORMAT(t.Date, '%Y-%m')
),

Monthly_Comparison AS
(
    SELECT
        Sales_Month,
        Net_Sales,
        Gross_Margin,
        Markdown_Net_Sales,

        LAG(Net_Sales, 1) OVER (
            ORDER BY Sales_Month
        ) AS Previous_Month_Sales,

        LAG(Net_Sales, 12) OVER (
            ORDER BY Sales_Month
        ) AS Previous_Year_Sales,

        LAG(Gross_Margin, 1) OVER (
            ORDER BY Sales_Month
        ) AS Previous_Month_Margin,

        LAG(Gross_Margin, 12) OVER (
            ORDER BY Sales_Month
        ) AS Previous_Year_Margin

    FROM Monthly_Summary
)

SELECT
    Sales_Month,
    Net_Sales,
    Gross_Margin,

    ROUND(
        (Net_Sales - Previous_Month_Sales)
        / NULLIF(Previous_Month_Sales, 0) * 100, 2
    ) AS MoM_Sales_Growth_Percentage,

    ROUND(
        (Net_Sales - Previous_Year_Sales)
        / NULLIF(Previous_Year_Sales, 0) * 100, 2
    ) AS YoY_Sales_Growth_Percentage,

    ROUND(
        (Gross_Margin - Previous_Month_Margin)
        / NULLIF(Previous_Month_Margin, 0) * 100, 2
    ) AS MoM_Margin_Growth_Percentage,

    ROUND(
        (Gross_Margin - Previous_Year_Margin)
        / NULLIF(Previous_Year_Margin, 0) * 100, 2
    ) AS YoY_Margin_Growth_Percentage,

    ROUND(
        Markdown_Net_Sales
        / NULLIF(Net_Sales, 0) * 100, 2
    ) AS Markdown_Sales_Share_Percentage

FROM Monthly_Comparison

ORDER BY Sales_Month;


-- =====================================================================================================
-- SECTION 4: PRODUCTS
-- =====================================================================================================

-- Products 

-- ---- Query 9: Top 10 products by net sales in each category (ROW_NUMBER) ------------------------------
-- Question : Which products drive sales in Woman, Man and Kids?
-- Logic    : Sum net sales USD per product; ROW_NUMBER() OVER (PARTITION BY Category ORDER BY sales DESC)
--            ranks products inside each category; the outer query keeps ranks 1-10.
-- Result   : Kids #1 Knit Skirt $350.8K, #2 Velcro Trainers $222.9K, #3 Cargo Shorts $198.8K.
--            Man #1 Basic Cardigan $1.17M, #2 Technical Overcoat $0.99M, #3 Skinny Jeans $0.94M.
--            Across the chain the top product is the ZW Collection Puffer Coat ($1.72M), then the Oversize
--            Blazer ($1.38M). Outerwear, blazers and denim dominate the top lists.
-- Takeaway : Hero items are outerwear and tailoring - exactly the categories most exposed to markdown risk,
--            so buying depth for them needs the most care.

-- 9. Top products. With ROW_NUMBER() or RANK() over each category, list the top 10 products by net sales in US dollars. 

SELECT *
FROM
(
    SELECT
        p.Category,
        p.Sub_Category,
        p.Product_ID,
        p.Description_EN,

        ROUND(SUM(t.Line_Total * fx.usd_rate), 2) AS Net_Sales,

        ROW_NUMBER() OVER (
            PARTITION BY p.Category
            ORDER BY SUM(t.Line_Total * fx.usd_rate) DESC
        ) AS Product_Rank

    FROM transactions t

    JOIN products p
        ON p.Product_ID = t.Product_ID

    JOIN exchange_rates fx
        ON fx.Currency = t.Currency

    GROUP BY
        p.Category,
        p.Sub_Category,
        p.Product_ID,
        p.Description_EN
) AS Ranked_Products

WHERE Product_Rank <= 10

ORDER BY
    Category,
    Product_Rank;

-- ---- Query 10: Pareto - what share of products makes up 80% of net sales -----------------------------
-- Question : How concentrated are sales?
-- Logic    : Aggregate net sales per product; ROW_NUMBER ranks products by sales; a window SUM() OVER () gives
--            total sales and a running SUM() OVER (ORDER BY sales DESC ROWS UNBOUNDED PRECEDING) gives
--            cumulative sales. Cumulative / total = cumulative share.
-- Result   : The top 10 products make up 7.6% of sales. The cumulative share crosses 80% at product rank 1,826
--            (80.01%), i.e. about 1,826 products or roughly a quarter of the 7,199-product catalogue.
-- Takeaway : A classic 80/20-style pattern: about 25% of products deliver 80% of sales, so the long tail of
--            ~75% of products adds only 20% of sales and is the first place to cut buying depth.

-- 10. Pareto. Using a running SUM() OVER, find what share of products makes up 80% of net sales. 


WITH Product_Analysis AS
(
    SELECT
        p.Product_ID,
        p.Description_EN,

        SUM(t.Line_Total * fx.usd_rate) AS Net_Sales,

        ROW_NUMBER() OVER (
            ORDER BY SUM(t.Line_Total * fx.usd_rate) DESC
        ) AS Product_Rank,

        SUM(SUM(t.Line_Total * fx.usd_rate)) OVER () AS Total_Sales,

        SUM(SUM(t.Line_Total * fx.usd_rate)) OVER (
            ORDER BY SUM(t.Line_Total * fx.usd_rate) DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS Cumulative_Sales

    FROM transactions t

    JOIN products p
        ON p.Product_ID = t.Product_ID

    JOIN exchange_rates fx
        ON fx.Currency = t.Currency

    GROUP BY
        p.Product_ID,
        p.Description_EN
)

SELECT
    Product_ID,
    Description_EN,
    ROUND(Net_Sales, 2) AS Net_Sales,
    Product_Rank,
    ROUND(Cumulative_Sales, 2) AS Cumulative_Sales,

    ROUND(
        Cumulative_Sales / Total_Sales * 100, 2
    ) AS Cumulative_Sales_Percentage

FROM Product_Analysis

ORDER BY Product_Rank;

-- ---- Query 11a: Return rate by sub-category, size, country and price type ----------------------------
-- Question : Where do returns concentrate?
-- Logic    : Return rate = units returned / units sold x 100, grouped by sub-category, size, store country and
--            Full Price vs Markdown. Sorted by return rate, highest first.
-- Result   : The extreme rates (100%+) are tiny samples (3-10 units) and should be ignored. Among
--            high-volume groups the worst are in Germany: Dresses XL 35.9% and XS 33.9%, Jeans size 36 32.7%
--            and size 32 30.3% (full price), and also Dresses in the UK and France (28-32%).
-- Takeaway : Dresses and jeans are the problem categories, and Germany returns the most. Fit and sizing (XS/XL
--            dresses, jeans sizes 32/36) are the likely cause.
-- Note     : This query groups by the raw stores.Country, so a country written in two languages (e.g.
--            "Deutschland" and "Germany") would appear separately. Join country_map, as Query 6 does, if
--            all countries must be shown in English.

-- 11. Returns. Return rate (units returned ÷ units sold) by sub-category, size, country and full price vs markdown.
--  Then find individual products whose return rate is far above their sub-category's, and suggest what might be wrong with them. 

SELECT
    p.Sub_Category,
    t.Size,
    s.Country,

    IF(t.Discount > 0, 'Markdown', 'Full Price') AS Price_Type,

    SUM(IF(t.Transaction_Type = 'Sale', t.Quantity, 0)) AS Units_Sold,

    SUM(IF(t.Transaction_Type = 'Return', t.Quantity, 0)) AS Units_Returned,

    ROUND(
        SUM(IF(t.Transaction_Type = 'Return', t.Quantity, 0))
        /
        NULLIF(
            SUM(IF(t.Transaction_Type = 'Sale', t.Quantity, 0)),
            0
        ) * 100,
        2
    ) AS Return_Rate_Percentage

FROM transactions t

JOIN products p
    ON p.Product_ID = t.Product_ID

JOIN stores s
    ON s.Store_ID = t.Store_ID

GROUP BY
    p.Sub_Category,
    t.Size,
    s.Country,
    Price_Type

ORDER BY
    Return_Rate_Percentage DESC;

-- ---- Query 11b: Products whose return rate is far above their sub-category's --------------------------
-- Question : Which individual products have abnormal returns, and what might be wrong?
-- Logic    : Product return rate vs the sub-category return rate (window SUM() OVER (PARTITION BY
--            Sub_Category)). The filter keeps every product that has returns.
-- Result   : Many outliers have 1-50 units sold, so the rate is noise. The meaningful ones have volume: the
--            Z1975 High-Waist Straight Jeans family (product IDs 6202, 3598, 4732, 6800, 6281, 1242, 6031,
--            6943), each with 1,250-1,420 units sold and a 33-36% return rate against 16.92% for the whole
--            Jeans sub-category - about double.
-- Why      : Same style repeated across many colours/IDs with identical return rates points to a common fit or
--            sizing problem (consistent with high returns on jeans sizes 32 and 36 in Query 11a), not a
--            one-colour issue.
-- Action   : Review the pattern / size chart with the supplier and add fit guidance on the product page.
--            Add a minimum-units rule (e.g. 100 units sold) to the filter so tiny samples are excluded.

-- Identify Products with High Return Rates than their Sub Category

WITH Product_Returns AS
(
    SELECT
        p.Sub_Category,
        p.Product_ID,
        p.Description_EN,

        SUM(IF(t.Transaction_Type = 'Sale', t.Quantity, 0)) AS Units_Sold,

        SUM(IF(t.Transaction_Type = 'Return', t.Quantity, 0)) AS Units_Returned,

        ROUND(
            SUM(IF(t.Transaction_Type = 'Return', t.Quantity, 0))
            / NULLIF(SUM(IF(t.Transaction_Type = 'Sale', t.Quantity, 0)), 0)
            * 100, 2
        ) AS Product_Return_Rate

    FROM transactions t

    JOIN products p
        ON p.Product_ID = t.Product_ID

    GROUP BY
        p.Sub_Category,
        p.Product_ID,
        p.Description_EN
)

SELECT
    Sub_Category,
    Product_ID,
    Description_EN,
    Units_Sold,
    Units_Returned,
    Product_Return_Rate,

    ROUND(
        SUM(Units_Returned) OVER (PARTITION BY Sub_Category)
        / NULLIF(SUM(Units_Sold) OVER (PARTITION BY Sub_Category), 0)
        * 100, 2
    ) AS Subcategory_Return_Rate

FROM Product_Returns

WHERE Product_Return_Rate >
(
    SELECT 0
)

ORDER BY
    Product_Return_Rate DESC;
    

-- ---- Query 12: Stored procedure promo_report(start_date, end_date, country_name) --------------------------
-- Question : Reusable report - sales, units and margin for a period against the period before.
-- Logic    : The previous period has the same number of days as the requested period and ends the day before
--            it starts (DATEDIFF + 1 days back). One pass over transactions uses SUM(IF(date in range, ...))
--            for "current" and "previous". Units use -Quantity for returns; margin = USD sales - USD cost.
-- Inputs   : start_date, end_date (DATE) and country_name (as stored in stores.Country).
-- Output   : One row: Current_Units, Current_Net_Sales, Current_Gross_Margin, Previous_Units,
--            Previous_Net_Sales, Previous_Gross_Margin.
-- Test     : CALL promo_report('2025-01-01', '2025-01-15', 'France');
--            -> current 8,326 units / $291,003 sales / $108,914 margin vs previous 10,817 units / $453,726 /
--            $211,152: units -23.0%, sales -35.9%, margin -48.4% (the previous period is the Christmas peak).

-- 12. Reusable report. Create a stored procedure, promo_report, that takes a start and end date and a country, 
-- and returns sales, units and margin against the period before. 

--  With Previous Period 

DELIMITER //

CREATE PROCEDURE promo_report(
    IN start_date DATE,
    IN end_date DATE,
    IN country_name VARCHAR(100)
)

BEGIN

    SELECT
        s.Country,

        /* Current Period */

        SUM(IF(
            t.Date >= start_date
            AND t.Date < DATE_ADD(end_date, INTERVAL 1 DAY),
            IF(t.Transaction_Type = 'Return', -t.Quantity, t.Quantity),
            0
        )) AS Current_Units,

        ROUND(SUM(IF(
            t.Date >= start_date
            AND t.Date < DATE_ADD(end_date, INTERVAL 1 DAY),
            t.Line_Total * fx.usd_rate,
            0
        )), 2) AS Current_Net_Sales,

        ROUND(SUM(IF(
            t.Date >= start_date
            AND t.Date < DATE_ADD(end_date, INTERVAL 1 DAY),
            (t.Line_Total * fx.usd_rate)
            -
            (IF(t.Transaction_Type = 'Return', -t.Quantity, t.Quantity)
            * p.Production_Cost * 1.08),
            0
        )), 2) AS Current_Gross_Margin,

        /* Previous Period */

        SUM(IF(
            t.Date >= DATE_SUB(start_date,
                INTERVAL (DATEDIFF(end_date, start_date) + 1) DAY)
            AND t.Date < start_date,
            IF(t.Transaction_Type = 'Return', -t.Quantity, t.Quantity),
            0
        )) AS Previous_Units,

        ROUND(SUM(IF(
            t.Date >= DATE_SUB(start_date,
                INTERVAL (DATEDIFF(end_date, start_date) + 1) DAY)
            AND t.Date < start_date,
            t.Line_Total * fx.usd_rate,
            0
        )), 2) AS Previous_Net_Sales,

        ROUND(SUM(IF(
            t.Date >= DATE_SUB(start_date,
                INTERVAL (DATEDIFF(end_date, start_date) + 1) DAY)
            AND t.Date < start_date,
            (t.Line_Total * fx.usd_rate)
            -
            (IF(t.Transaction_Type = 'Return', -t.Quantity, t.Quantity)
            * p.Production_Cost * 1.08),
            0
        )), 2) AS Previous_Gross_Margin

    FROM transactions t

    JOIN products p
        ON p.Product_ID = t.Product_ID

    JOIN stores s
        ON s.Store_ID = t.Store_ID

    JOIN exchange_rates fx
        ON fx.Currency = t.Currency

    WHERE
        s.Country = country_name

        AND t.Date >= DATE_SUB(
            start_date,
            INTERVAL (DATEDIFF(end_date, start_date) + 1) DAY
        )

        AND t.Date < DATE_ADD(end_date, INTERVAL 1 DAY)

    GROUP BY
        s.Country;

END //

DELIMITER ;


-- Example call (see the Test note above)

CALL promo_report('2025-01-01', '2025-01-15', 'France');