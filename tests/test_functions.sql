-- Tests for the event reservation schema and its PL/pgSQL functions.
-- Run after loading SGBD_sql.sql:
--   psql -v ON_ERROR_STOP=1 -d <db> -f tests/test_functions.sql
-- Everything runs in a transaction that is rolled back, so the database is left untouched.

\set ON_ERROR_STOP on
BEGIN;

-- Fixtures -------------------------------------------------------------------
SELECT create_user('alice', 'hash-a', 'alice@example.com');
SELECT create_user('bob', 'hash-b', 'bob@example.com');
SELECT Insert_Location('Salle Atlas', 'Algiers');
SELECT Insert_SeatType('VIP', 1, 50,
    (SELECT location_id FROM Location WHERE location_name = 'Salle Atlas'));
SELECT Insert_Event('AI Summit', DATE '2026-12-01', TIMESTAMP '2026-12-01 18:00', 25.00, 100,
    (SELECT user_id FROM "User" WHERE username = 'alice'));
SELECT Insert_Event('Jazz Night', DATE '2026-12-05', TIMESTAMP '2026-12-05 20:00', 15.00, 40,
    (SELECT user_id FROM "User" WHERE username = 'alice'));

CREATE TEMP TABLE ids ON COMMIT DROP AS
SELECT
    (SELECT user_id FROM "User" WHERE username = 'alice') AS alice,
    (SELECT user_id FROM "User" WHERE username = 'bob') AS bob,
    (SELECT event_id FROM Event WHERE event_name = 'AI Summit') AS summit,
    (SELECT event_id FROM Event WHERE event_name = 'Jazz Night') AS jazz,
    (SELECT location_id FROM Location WHERE location_name = 'Salle Atlas') AS atlas,
    (SELECT type_id FROM SeatType WHERE type_name = 'VIP') AS vip;

SELECT Insert_Reservation(bob, summit, 1, 'confirmed') FROM ids;
SELECT Insert_Reservation(bob, summit, 2, 'confirmed') FROM ids;
SELECT Insert_Reservation(alice, summit, 3, 'pending') FROM ids;
SELECT Insert_Reservation(alice, jazz, 7, 'confirmed') FROM ids;

SELECT Insert_Transaction(bob, r.reservation_id, 25.00, 'card', 'paid')
FROM ids, Reservation r WHERE r.event_id = ids.summit AND r.seatNumber IN (1, 2);
SELECT Insert_Transaction(alice, r.reservation_id, 15.00, 'cash', 'paid')
FROM ids, Reservation r WHERE r.event_id = ids.jazz;

SELECT Insert_TicketPrice(summit, vip, 40.00) FROM ids;
SELECT Insert_EventDate(summit, atlas) FROM ids;

-- Users ------------------------------------------------------------------------
DO $$
DECLARE r RECORD;
BEGIN
    SELECT * INTO r FROM get_user_info('alice');
    ASSERT r.user_email = 'alice@example.com', 'get_user_info returns email';
    ASSERT r.registration_datee IS NOT NULL, 'registration_date defaults to now';
    ASSERT NOT EXISTS (SELECT 1 FROM get_user_info('nobody')), 'unknown user returns no row';
END $$;

DO $$
BEGIN
    PERFORM update_user((SELECT bob FROM ids), 'bobby', 'bobby@example.com');
    ASSERT (SELECT username FROM "User" WHERE user_id = (SELECT bob FROM ids)) = 'bobby',
        'update_user changes username';
    ASSERT (SELECT email FROM "User" WHERE user_id = (SELECT bob FROM ids)) = 'bobby@example.com',
        'update_user changes email';
END $$;

DO $$
BEGIN
    BEGIN
        PERFORM create_user('alice', 'x', 'other@example.com');
        RAISE EXCEPTION 'duplicate username was accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    BEGIN
        PERFORM create_user('carol', 'x', 'alice@example.com');
        RAISE EXCEPTION 'duplicate email was accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
END $$;

-- Events and reservations -----------------------------------------------------
DO $$
BEGIN
    ASSERT get_total_sold_tickets((SELECT summit FROM ids)) = 2,
        'only confirmed reservations count as sold';
    ASSERT get_total_sold_tickets((SELECT jazz FROM ids)) = 1, 'sold tickets per event';
    ASSERT get_total_sold_tickets(-1) = 0, 'unknown event has 0 sold tickets';
END $$;

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM get_user_events((SELECT alice FROM ids))) = 2,
        'get_user_events lists events created by the user';
    ASSERT (SELECT bool_and(creator_username = 'alice') FROM get_user_events((SELECT alice FROM ids))),
        'get_user_events returns the creator username';
    ASSERT (SELECT count(*) FROM get_user_events((SELECT bob FROM ids))) = 0,
        'user without events gets none';
END $$;

DO $$
DECLARE r RECORD;
BEGIN
    ASSERT (SELECT count(*) FROM get_user_reservations((SELECT alice FROM ids))) = 2,
        'get_user_reservations lists all reservations of the user';
    SELECT * INTO r FROM get_user_reservations((SELECT bob FROM ids)) ORDER BY seat_number LIMIT 1;
    ASSERT r.event_name = 'AI Summit' AND r.seat_number = 1 AND r.status = 'confirmed',
        'reservation joined with its event';
END $$;

DO $$
DECLARE r RECORD; rid INTEGER;
BEGIN
    SELECT reservation_id INTO rid FROM Reservation WHERE seatNumber = 7;
    SELECT * INTO r FROM get_reservation_info(rid);
    ASSERT r.v_reservation_id = rid AND r.v_seat_number = 7 AND r.v_status = 'confirmed',
        'get_reservation_info returns the reservation';
END $$;

DO $$
BEGIN
    ASSERT (SELECT status FROM Reservation WHERE reservation_id =
            (SELECT max(reservation_id) FROM Reservation)) = 'confirmed', 'status stored';
    INSERT INTO Reservation (user_id, event_id, seatNumber) SELECT bob, jazz, 9 FROM ids;
    ASSERT (SELECT status FROM Reservation WHERE seatNumber = 9) = 'pending',
        'reservation status defaults to pending';
END $$;

-- Transactions and revenue ----------------------------------------------------
DO $$
BEGIN
    ASSERT CalculateEventRevenue((SELECT summit FROM ids)) = 50.00, 'revenue sums event transactions';
    ASSERT CalculateEventRevenue((SELECT jazz FROM ids)) = 15.00, 'revenue per event';
    ASSERT CalculateEventRevenue(-1) = 0.00, 'revenue is 0, not NULL, without transactions';
END $$;

DO $$
DECLARE tid INTEGER;
BEGIN
    ASSERT (SELECT count(*) FROM get_user_transactions((SELECT bob FROM ids))) = 2,
        'get_user_transactions';
    ASSERT (SELECT count(*) FROM GetUserTotalTransactions((SELECT bob FROM ids))) = 2,
        'GetUserTotalTransactions';
    SELECT transaction_id INTO tid FROM Transactions WHERE payment_method = 'cash';
    ASSERT (SELECT amount FROM get_transaction_details(tid)) = 15.00, 'get_transaction_details';
END $$;

-- Referential integrity -------------------------------------------------------
DO $$
BEGIN
    DELETE FROM EventDate WHERE event_id = (SELECT summit FROM ids);
    DELETE FROM Event WHERE event_id = (SELECT summit FROM ids);
    ASSERT NOT EXISTS (SELECT 1 FROM Reservation WHERE event_id = (SELECT summit FROM ids)),
        'deleting an event cascades to its reservations';
    ASSERT NOT EXISTS (SELECT 1 FROM TicketPrice WHERE event_id = (SELECT summit FROM ids)),
        'deleting an event cascades to its ticket prices';
    ASSERT (SELECT count(*) FROM Transactions WHERE user_id = (SELECT bob FROM ids)) = 0,
        'and to the transactions of those reservations';
END $$;

DO $$
BEGIN
    BEGIN
        PERFORM Insert_Reservation(-1, (SELECT jazz FROM ids), 1, 'pending');
        RAISE EXCEPTION 'reservation for unknown user was accepted';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
END $$;

\echo 'All SQL tests passed'
ROLLBACK;
